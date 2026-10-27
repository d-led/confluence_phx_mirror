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

  defp added, do: Enum.map(Settings.wanted_spaces(), &Space.normalise_key/1)

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
