defmodule ConfluencePhxMirror.Settings do
  @moduledoc """
  Decisions an administrator makes at runtime, as opposed to the environment
  the mirror booted with.

  Three settings today:

    * `:theme` — the theme the whole site wears. Readers only pick the variant
      (light, dark, system). `CM_THEME` seeds it and takes over again when the
      stored value is cleared.
    * `:webhook_require_signature` — overrides `CM_WEBHOOK_REQUIRE_SIGNATURE`.
    * `:webhook_rate_limit` — overrides `CM_WEBHOOK_RATE_LIMIT_PER_MINUTE`.

  A setting that was never stored reads as `nil`, meaning "no decision here":
  callers fall back to what the deployment configured. That is what makes an
  override an override rather than a second default in a different place.

  Reads are served from `:persistent_term`, so a per-request lookup never
  touches the database — the values are loaded once at boot and updated on
  every write. Writes are audited; an unauditable change does not happen.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.{Audit, Repo}
  alias ConfluencePhxMirror.Audit.Entry
  alias ConfluencePhxMirror.Settings.Setting

  # Every key an administrator can own, and how the stored string becomes a
  # value again.
  @types %{
    "theme" => :string,
    "webhook.require_signature" => :boolean,
    "webhook.rate_limit" => :integer
  }

  @doc "The theme an administrator set, or `nil` when none is stored."
  @spec theme() :: String.t() | nil
  def theme, do: read("theme")

  @doc "Whether an administrator required webhook signatures, or `nil` when the deployment decides."
  @spec webhook_require_signature() :: boolean() | nil
  def webhook_require_signature, do: read("webhook.require_signature")

  @doc "The webhook intake cap an administrator set, or `nil` when the deployment decides."
  @spec webhook_rate_limit() :: pos_integer() | nil
  def webhook_rate_limit, do: read("webhook.rate_limit")

  @doc """
  Loads every stored setting into memory. Called once, after the repository is
  up, so the request path never reads the table.
  """
  @spec load() :: :ok
  def load do
    keys = Map.keys(@types)

    stored =
      from(s in Setting, where: s.key in ^keys, select: {s.key, s.value})
      |> Repo.all()
      |> Map.new()

    Enum.each(@types, fn {key, _type} ->
      :persistent_term.put(term(key), decode(key, Map.get(stored, key)))
    end)
  end

  @doc "Re-reads the table, e.g. after a manual `UPDATE` in psql."
  @spec reload() :: :ok
  def reload, do: load()

  @doc """
  Drops the cached value without reading the table.

  The cache is `:persistent_term`, which a rolled-back test transaction does not
  roll back: a test that stored a theme would leave the next one rendering a
  theme nobody chose. `reload/0` cannot put the cache back in that case,
  because the uncommitted row is still visible while the test cleans up — so the
  suite forgets between tests instead.
  """
  @spec forget() :: :ok
  def forget do
    Enum.each(@types, fn {key, _type} -> :persistent_term.erase(term(key)) end)
    :ok
  end

  @doc """
  Sets the theme, or clears it with `nil`/`""`, and records who did it.
  """
  @spec put_theme(String.t() | nil, Audit.actor()) :: :ok
  def put_theme(name, actor) do
    name = blank_to_nil(name)
    store("theme", name, actor, "settings.theme", %{theme: name || "none"})
  end

  @doc """
  Requires webhook signatures (`true`), accepts unsigned deliveries (`false`),
  or drops the decision so the deployment's own setting applies again (`nil`).
  """
  @spec put_webhook_require_signature(boolean() | nil, Audit.actor()) :: :ok
  def put_webhook_require_signature(required?, actor)
      when is_boolean(required?) or is_nil(required?) do
    store("webhook.require_signature", required?, actor, "settings.webhook_signature", %{
      required: required?
    })
  end

  @doc """
  Caps the webhook intake at `per_minute`, or drops the decision with `nil` so
  `CM_WEBHOOK_RATE_LIMIT_PER_MINUTE` applies again.
  """
  @spec put_webhook_rate_limit(pos_integer() | nil, Audit.actor()) :: :ok
  def put_webhook_rate_limit(nil, actor) do
    store("webhook.rate_limit", nil, actor, "settings.webhook_rate_limit", %{per_minute: nil})
  end

  def put_webhook_rate_limit(per_minute, actor) when is_integer(per_minute) and per_minute > 0 do
    store("webhook.rate_limit", per_minute, actor, "settings.webhook_rate_limit", %{
      per_minute: per_minute
    })
  end

  defp store(key, value, actor, action, metadata) do
    %Setting{}
    |> Setting.changeset(%{key: key, value: encode(value)})
    |> Repo.insert!(
      on_conflict: {:replace, [:value]},
      conflict_target: :key
    )

    Audit.log(actor, Entry.new(action, "settings", key, metadata))

    :persistent_term.put(term(key), value)
  end

  defp read(key), do: :persistent_term.get(term(key), nil)

  defp term(key), do: {__MODULE__, key}

  defp encode(nil), do: nil
  defp encode(value) when is_binary(value), do: value
  defp encode(value) when is_integer(value), do: Integer.to_string(value)
  defp encode(value) when is_boolean(value), do: to_string(value)

  defp decode(_key, nil), do: nil

  defp decode(key, value) do
    case Map.fetch!(@types, key) do
      :string -> value
      :boolean -> value in ~w(true 1 yes)
      :integer -> String.to_integer(value)
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(name) when is_binary(name), do: name
end
