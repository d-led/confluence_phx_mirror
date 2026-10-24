defmodule ConfluencePhxMirror.Settings do
  @moduledoc """
  The configuration an administrator can change while the mirror runs.

  Everything here has a **default taken from the deployment's own
  configuration** (`config/*.exs` and the `CM_*` variables that feed it), so a
  mirror nobody has touched in the browser behaves exactly as its config says. A
  stored value is an override of that default; clearing it hands the decision
  back. This is the difference between "a second default in a different place"
  and a real setting.

  | key | decides | default from |
  | --- | --- | --- |
  | `theme` | the theme every reader wears | `:theme` (`CM_THEME`) |
  | `reader.html_limit` | HTML requests per reader per minute | `:reader_rate_limit, :html` (`CM_READER_RATE_LIMIT_PER_MINUTE`) |
  | `reader.api_limit` | API requests per reader per minute | `:reader_rate_limit, :api` |
  | `reader.attachments_limit` | attachment downloads per reader per minute | `:reader_rate_limit, :attachments` |
  | `notifications.enabled` | whether the mirror sends e-mail at all | `:notifications, :enabled` |
  | `notifications.digest_hour_utc` | the hour daily digests go out | `:notifications, :digest_hour_utc` |
  | `webhook.enabled` | whether the intake accepts deliveries at all | `:webhooks, :enabled` |
  | `webhook.require_signature` | whether deliveries must be signed | `:webhooks, :require_signature` |
  | `webhook.rate_limit` | deliveries accepted per address per minute | `:webhook_rate_limit, :limit` |

  Only settings whose readers look at the value while serving a request belong
  here. Anything read once at boot — the source, the sync schedule, the
  database — is still environment-only, and `/admin/settings` says so rather
  than pretending otherwise.

  ## Reads and writes

  Reads never touch the database: `load/0` fills `:persistent_term` at boot and
  every write refreshes it.

  A write is **one transaction**: the rows and the audit entry commit together
  or not at all, and the cache is updated only after the commit returns. A
  change that cannot be audited therefore does not happen, and a failed save
  leaves both the table and the running site exactly as they were.
  """

  require Logger

  # `from/2` only: importing the whole of Ecto.Query would shadow this module's
  # own `update/2`.
  import Ecto.Query, only: [from: 2]

  alias ConfluencePhxMirror.{Audit, Repo}
  alias ConfluencePhxMirror.Audit.Entry
  alias ConfluencePhxMirror.Settings.Setting

  @type value :: String.t() | boolean() | integer() | nil
  @type changes :: %{optional(String.t()) => value()}

  # type:    how a stored string becomes a value again, and what a write accepts
  # default: where the deployment's own value comes from (`resolve/1` reads it),
  #          so a setting nobody stored behaves exactly as the config says
  @specs %{
    "theme" => %{type: :string, default: :theme},
    "reader.html_limit" => %{type: :pos_integer, default: {:reader_limit, :html, 240}},
    "reader.api_limit" => %{type: :pos_integer, default: {:reader_limit, :api, 120}},
    "reader.attachments_limit" => %{
      type: :pos_integer,
      default: {:reader_limit, :attachments, 300}
    },
    "notifications.enabled" => %{type: :boolean, default: {:notification, :enabled, true}},
    "notifications.digest_hour_utc" => %{
      type: :hour,
      default: {:notification, :digest_hour_utc, 8}
    },
    "webhook.enabled" => %{type: :boolean, default: {:webhook, :enabled, true}},
    "webhook.require_signature" => %{type: :boolean, default: {:webhook, :require_signature}},
    "webhook.rate_limit" => %{type: :pos_integer, default: {:webhook, :limit}}
  }

  @doc "Every key an administrator can own, in a stable order."
  @spec keys() :: [String.t()]
  def keys, do: @specs |> Map.keys() |> Enum.sort()

  @doc "Whether `key` is a setting this mirror knows."
  @spec known?(String.t()) :: boolean()
  def known?(key), do: Map.has_key?(@specs, key)

  @doc """
  What applies when nothing is stored: the deployment's own configuration.

  `nil` means the deployment says nothing either — the caller decides what to do
  with that (a reader limit falls back to the built-in floor, an empty theme to
  the compiled-in default).
  """
  @spec default(String.t()) :: value()
  def default(key), do: resolve(fetch!(key).default)

  @doc "The value an administrator stored, or `nil` when they never decided."
  @spec stored(String.t()) :: value()
  def stored(key), do: :persistent_term.get(term(key), nil)

  @doc "The value in force: the stored one, else the deployment's default."
  @spec effective(String.t()) :: value()
  def effective(key) do
    case stored(key) do
      nil -> default(key)
      value -> value
    end
  end

  @doc "The theme every reader wears."
  @spec theme() :: String.t() | nil
  def theme, do: effective("theme")

  @doc "Requests a reader may make per minute in `scope` (`:html`, `:api`, `:attachments`)."
  @spec reader_limit(atom() | String.t()) :: pos_integer()
  def reader_limit(scope), do: effective("reader.#{scope}_limit")

  @doc "Whether the mirror sends notification mail at all."
  @spec notifications_enabled?() :: boolean()
  def notifications_enabled?, do: effective("notifications.enabled")

  @doc "The UTC hour the daily digest goes out."
  @spec digest_hour_utc() :: 0..23
  def digest_hour_utc, do: effective("notifications.digest_hour_utc")

  @doc "Whether the webhook intake accepts deliveries at all."
  @spec webhook_enabled?() :: boolean()
  def webhook_enabled?, do: effective("webhook.enabled")

  @doc "Whether webhook deliveries must be signed."
  @spec webhook_require_signature() :: boolean() | nil
  def webhook_require_signature, do: effective("webhook.require_signature")

  @doc "Deliveries accepted per address per minute."
  @spec webhook_rate_limit() :: pos_integer() | nil
  def webhook_rate_limit, do: effective("webhook.rate_limit")

  @doc """
  Loads every stored setting into memory. Called once, after the repository is
  up, so the request path never reads the table.
  """
  @spec load() :: :ok
  def load do
    stored =
      from(s in Setting, where: s.key in ^keys(), select: {s.key, s.value})
      |> Repo.all()
      |> Map.new()

    Enum.each(@specs, fn {key, _spec} ->
      :persistent_term.put(term(key), decode(key, Map.get(stored, key)))
    end)
  end

  @doc "Re-reads the table, e.g. after a manual `UPDATE` in psql."
  @spec reload() :: :ok
  def reload, do: load()

  @doc """
  Drops the cached values without reading the table.

  The cache is `:persistent_term`, which a rolled-back test transaction does not
  roll back: a test that stored a setting would leave the next one rendering a
  value nobody chose. `reload/0` cannot put the cache back in that case, because
  the uncommitted row is still visible while the test cleans up — so the suite
  forgets between tests instead.
  """
  @spec forget() :: :ok
  def forget do
    Enum.each(@specs, fn {key, _spec} -> :persistent_term.erase(term(key)) end)
    :ok
  end

  @doc """
  Applies several settings as one change.

  Every value is validated first; then the rows and a single audit entry are
  written in one transaction; then the cache is updated. `nil` or a blank string
  clears a key, so the deployment's default applies again.

      {:ok, %{"reader.html_limit" => 240}}      = Settings.update(%{"reader.html_limit" => "240"}, actor)
      {:error, {:invalid_value, "reader.api_limit", "lots"}} = ...
  """
  @spec update(changes(), Audit.actor()) :: {:ok, changes()} | {:error, term()}
  def update(changes, actor) when is_map(changes) do
    with {:ok, cast} <- cast_all(changes) do
      commit(cast, actor)
    end
  end

  @doc "Hands `keys` back to the deployment's configuration."
  @spec clear([String.t()], Audit.actor()) :: {:ok, changes()} | {:error, term()}
  def clear(keys, actor) when is_list(keys) do
    update(Map.new(keys, &{&1, nil}), actor)
  end

  @doc "Sets the theme, or clears it with `nil`/`\"\"`."
  @spec put_theme(String.t() | nil, Audit.actor()) :: {:ok, changes()} | {:error, term()}
  def put_theme(name, actor), do: update(%{"theme" => name}, actor)

  @doc "Requires webhook signatures, accepts unsigned deliveries, or drops the decision."
  @spec put_webhook_require_signature(boolean() | nil, Audit.actor()) ::
          {:ok, changes()} | {:error, term()}
  def put_webhook_require_signature(required?, actor) do
    update(%{"webhook.require_signature" => required?}, actor)
  end

  @doc "Accepts webhook deliveries, refuses them, or drops the decision."
  @spec put_webhook_enabled(boolean() | nil, Audit.actor()) ::
          {:ok, changes()} | {:error, term()}
  def put_webhook_enabled(enabled?, actor) do
    update(%{"webhook.enabled" => enabled?}, actor)
  end

  @doc "Caps the webhook intake at `per_minute`, or drops the decision with `nil`."
  @spec put_webhook_rate_limit(pos_integer() | nil, Audit.actor()) ::
          {:ok, changes()} | {:error, term()}
  def put_webhook_rate_limit(per_minute, actor) do
    update(%{"webhook.rate_limit" => per_minute}, actor)
  end

  defp commit(changes, actor) do
    result =
      Repo.transaction(fn ->
        Enum.each(changes, fn {key, value} -> write_row(key, value) end)
        audit(actor, changes)
      end)

    case result do
      {:ok, _} ->
        put_cache(changes)
        {:ok, changes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_row(key, nil) do
    Repo.delete_all(from s in Setting, where: s.key == ^key)
    :ok
  end

  defp write_row(key, value) do
    %Setting{}
    |> Setting.changeset(%{key: key, value: encode(value)})
    |> Repo.insert(on_conflict: {:replace, [:value]}, conflict_target: :key)
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> Repo.rollback({:not_stored, key, changeset})
    end
  end

  # `Audit.log/2` raises when it cannot write: inside this transaction that
  # rolls the rows back with it, which is the whole point — an unauditable
  # change does not happen.
  defp audit(actor, changes) do
    Audit.log(actor, entry(changes))
  rescue
    error -> Repo.rollback({:not_audited, error})
  end

  defp entry(changes) do
    Entry.new(
      "settings.updated",
      "settings",
      changes |> Map.keys() |> Enum.sort() |> Enum.join(","),
      %{"changes" => Map.new(changes, fn {key, value} -> {key, spoken(value)} end)}
    )
  end

  defp spoken(nil), do: "deployment default"
  defp spoken(value) when is_boolean(value), do: value
  defp spoken(value), do: to_string(value)

  defp put_cache(changes) do
    Enum.each(changes, fn {key, value} -> :persistent_term.put(term(key), value) end)
  end

  defp cast_all(changes) do
    Enum.reduce_while(changes, {:ok, %{}}, fn {key, value}, {:ok, cast} ->
      case cast_one(to_string(key), value) do
        {:ok, value} -> {:cont, {:ok, Map.put(cast, to_string(key), value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cast_one(key, value) do
    if known?(key) do
      case coerce(fetch!(key).type, blank_to_nil(value)) do
        {:ok, cast} -> {:ok, cast}
        :error -> {:error, {:invalid_value, key, value}}
      end
    else
      {:error, {:unknown_key, key}}
    end
  end

  # A blank field in a form means "no decision" whatever the type, which is how
  # the deployment's default comes back without a second kind of button.
  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp coerce(:string, value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp coerce(:string, nil), do: {:ok, nil}
  defp coerce(:boolean, value) when is_boolean(value), do: {:ok, value}
  defp coerce(:boolean, nil), do: {:ok, nil}

  defp coerce(:boolean, value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      truthy when truthy in ~w(true 1 yes on) -> {:ok, true}
      falsy when falsy in ~w(false 0 no off) -> {:ok, false}
      _other -> :error
    end
  end

  defp coerce(:pos_integer, nil), do: {:ok, nil}

  defp coerce(:pos_integer, value) do
    case to_integer(value) do
      number when is_integer(number) and number > 0 -> {:ok, number}
      _other -> :error
    end
  end

  defp coerce(:hour, nil), do: {:ok, nil}

  defp coerce(:hour, value) do
    case to_integer(value) do
      hour when is_integer(hour) and hour in 0..23 -> {:ok, hour}
      _other -> :error
    end
  end

  defp coerce(_type, _value), do: :error

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _other -> :error
    end
  end

  defp to_integer(_value), do: :error

  # A hand-edited row that no longer parses is worth a warning, not a crash: the
  # site keeps serving the deployment's default.
  defp decode(_key, nil), do: nil

  defp decode(key, value) do
    case coerce(fetch!(key).type, value) do
      {:ok, cast} ->
        cast

      :error ->
        Logger.warning(
          "ignoring unreadable setting #{key} (stored as #{inspect(value)}); " <>
            "the deployment's own value applies"
        )

        nil
    end
  end

  # `nil` never reaches here: `write_row/2` turns "no decision" into a delete.
  defp encode(value) when is_binary(value), do: value
  defp encode(value) when is_integer(value), do: Integer.to_string(value)
  defp encode(value) when is_boolean(value), do: to_string(value)

  defp fetch!(key) do
    case Map.fetch(@specs, key) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, "#{inspect(key)} is not a setting this mirror knows"
    end
  end

  defp term(key), do: {__MODULE__, key}

  defp configured(key), do: Application.get_env(:confluence_phx_mirror, key)

  # Where each default comes from: the same keys the environment sets, so a
  # setting and its variable can never drift apart.
  defp resolve(:theme), do: configured(:theme)
  defp resolve({:reader_limit, scope, floor}), do: reader_default(scope, floor)
  defp resolve({:notification, key, floor}), do: notification_default(key, floor)

  defp resolve({:webhook, :enabled, default}) do
    :confluence_phx_mirror
    |> Application.get_env(:webhooks, [])
    |> Keyword.get(:enabled, default)
  end

  defp resolve({:webhook, :require_signature}) do
    :confluence_phx_mirror
    |> Application.get_env(:webhooks, [])
    |> Keyword.get(:require_signature, false)
  end

  defp resolve({:webhook, :limit}) do
    :confluence_phx_mirror
    |> Application.get_env(:webhook_rate_limit, [])
    |> Keyword.get(:limit, 60)
  end

  defp reader_default(scope, floor) do
    :confluence_phx_mirror
    |> Application.get_env(:reader_rate_limit, [])
    |> Keyword.get(scope, [])
    |> Keyword.get(:limit, floor)
  end

  defp notification_default(key, floor) do
    :confluence_phx_mirror
    |> Application.get_env(:notifications, [])
    |> Keyword.get(key, floor)
  end
end
