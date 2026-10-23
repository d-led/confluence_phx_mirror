defmodule ConfluencePhxMirror.Settings do
  @moduledoc """
  Decisions an administrator makes at runtime, as opposed to the environment
  the mirror booted with.

  There is one setting today: the **theme** the whole site wears. It is the
  administrator's choice; readers only pick the variant (light, dark, system).
  `CM_THEME` (or `config :confluence_phx_mirror, :theme`) seeds it for
  deployments that want it without a manual step, and takes over again when the
  stored value is cleared.

  Reads are served from `:persistent_term`, so the per-request theme lookup
  never touches the database — the value is loaded once at boot and updated on
  every write. Writes are audited; an unauditable change does not happen.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.{Audit, Repo}
  alias ConfluencePhxMirror.Audit.Entry
  alias ConfluencePhxMirror.Settings.Setting

  @key "theme"
  @term {__MODULE__, :theme}

  @doc "The theme an administrator set, or `nil` when none is stored."
  @spec theme() :: String.t() | nil
  def theme, do: :persistent_term.get(@term, nil)

  @doc """
  Loads the stored settings into memory. Called once, after the repository is
  up, so the request path never reads the table.
  """
  @spec load() :: :ok
  def load do
    value = Repo.one(from s in Setting, where: s.key == ^@key, select: s.value)
    :persistent_term.put(@term, value)
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
    :persistent_term.erase(@term)
    :ok
  end

  @doc """
  Sets the theme, or clears it with `nil`/`""`, and records who did it.
  """
  @spec put_theme(String.t() | nil, Audit.actor()) :: :ok
  def put_theme(name, actor) do
    name = blank_to_nil(name)

    %Setting{}
    |> Setting.changeset(%{key: @key, value: name})
    |> Repo.insert!(
      on_conflict: {:replace, [:value]},
      conflict_target: :key
    )

    Audit.log(
      actor,
      Entry.new("settings.theme", "settings", @key, %{theme: name || "none"})
    )

    :persistent_term.put(@term, name)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(name) when is_binary(name), do: name
end
