defmodule ConfluencePhxMirror.Sync.SpaceScope do
  @moduledoc """
  Which spaces a run may import.

  Two lists decide it, and they add up rather than override:

    * the deployment's own keys — `CM_SPACES`, the floor, fixed at boot;
    * the ones an administrator added on the settings screen — `sync.spaces`.

  Neither naming anything means `:all`, which is how a mirror behaves when
  nobody has said otherwise: no setting, no change in behaviour.

  Once the deployment names spaces, the runtime list can only **widen** it.
  That is deliberate. Removing a key at runtime would narrow a mirror by
  accident, and a key the environment still names would reappear at the next
  boot anyway, so the screen would be lying about what is in force.

  When the deployment names nothing, the runtime list *is* the whitelist — the
  first key entered on a mirror that was holding everything narrows it to that
  key, and the next run trashes the rest (softly: rows stay, and naming them
  again brings them back). The settings screen says so where the field is.
  """

  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Mirror.Space
  alias ConfluencePhxMirror.Settings

  @doc "The space keys a run may import, or `:all`."
  @spec wanted() :: :all | [String.t()]
  def wanted do
    case {configured(), added()} do
      {:all, []} -> :all
      {:all, added} -> added
      {keys, []} -> keys
      {keys, added} -> Enum.uniq(keys ++ added)
    end
  end

  @doc "Whether space `key` may be imported, given a scope already read by `wanted/0`."
  @spec import?(:all | [String.t()], String.t()) :: boolean()
  def import?(:all, _key), do: true
  def import?(keys, key) when is_list(keys), do: Space.normalise_key(key) in keys

  @doc "Whether space `key` may be imported."
  @spec import?(String.t()) :: boolean()
  def import?(key), do: import?(wanted(), key)

  @doc "The keys the deployment fixes at boot, normalised."
  @spec fixed() :: [String.t()]
  def fixed do
    case configured() do
      :all -> []
      keys -> keys
    end
  end

  @doc "The keys an administrator added at runtime."
  @spec added() :: [String.t()]
  def added, do: Enum.map(Settings.wanted_spaces(), &Space.normalise_key/1)

  @doc """
  Adds `key` to the runtime list.

  Idempotent, and never duplicates what the deployment already names: a key the
  environment fixes is in force whether or not it is written down here.
  """
  @spec add(String.t(), Audit.actor()) :: {:ok, map()} | {:error, term()}
  def add(key, actor) do
    key = Space.normalise_key(key)
    keys = added()

    if key in keys or key in fixed() do
      {:ok, %{"sync.spaces" => keys}}
    else
      Settings.update(%{"sync.spaces" => keys ++ [key]}, actor)
    end
  end

  @doc """
  Takes `key` back out of the runtime list.

  A key the environment names stays in force: the variable would restore it at
  the next boot, so removing it here would only make the screen disagree with
  the run.
  """
  @spec remove(String.t(), Audit.actor()) :: {:ok, map()} | {:error, term()}
  def remove(key, actor) do
    Settings.update(%{"sync.spaces" => added() -- [Space.normalise_key(key)]}, actor)
  end

  # `CM_SPACES` lives in the HTTP source's own configuration, where the
  # environment writes it and where `/admin/settings` reports it. The demo and
  # synthetic sources have no site spaces to name, so they hold everything.
  defp configured do
    case Application.get_env(:confluence_phx_mirror, HttpSource, [])[:spaces] do
      nil -> :all
      :all -> :all
      [] -> :all
      keys when is_list(keys) -> Enum.map(keys, &Space.normalise_key/1)
    end
  end
end
