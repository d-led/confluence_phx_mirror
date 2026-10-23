defmodule ConfluencePhxMirror.Settings do
  @moduledoc """
  Decisions an administrator makes at runtime, as opposed to the environment
  the mirror booted with.

  There is one setting today: the **site skin**. It wins over the reader's
  cookie and hides the theme picker in the header; clearing it hands the choice
  back to readers. `CM_SITE_SKIN` (or `config :confluence_phx_mirror,
  :site_skin`) still seeds it for deployments that want it without a manual
  step, and takes over again when the stored value is cleared.

  Reads are served from `:persistent_term`, so the per-request theme lookup
  never touches the database — the value is loaded once at boot and updated on
  every write. Writes are audited; an unauditable change does not happen.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.{Audit, Repo}
  alias ConfluencePhxMirror.Audit.Entry
  alias ConfluencePhxMirror.Settings.Setting

  @key "site_skin"
  @term {__MODULE__, :site_skin}

  @doc "The site skin an administrator set, or `nil` when none is set."
  @spec site_skin() :: String.t() | nil
  def site_skin, do: :persistent_term.get(@term, nil)

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
  Sets the site skin, or clears it with `nil`/`""`, and records who did it.
  """
  @spec put_site_skin(String.t() | nil, Audit.actor()) :: :ok
  def put_site_skin(name, actor) do
    name = blank_to_nil(name)

    %Setting{}
    |> Setting.changeset(%{key: @key, value: name})
    |> Repo.insert!(
      on_conflict: {:replace, [:value]},
      conflict_target: :key
    )

    Audit.log(
      actor,
      Entry.new("settings.site_skin", "settings", @key, %{site_skin: name || "none"})
    )

    :persistent_term.put(@term, name)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(name) when is_binary(name), do: name
end
