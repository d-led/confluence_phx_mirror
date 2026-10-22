defmodule ConfluencePhxMirror.Config.IdentityGuard do
  @moduledoc """
  Which environments may honour the identity shortcuts.

  Three settings hand out an identity without a sign-in: `MIRROR_AUTO_ADMIN`
  (every visitor is the bootstrap administrator), `MIRROR_SELF_SIGNUP` (any
  address may request a magic link) and `CM_PROXY_AUTH` (the identity comes from
  a request header the proxy is supposed to set). They exist for development and
  for the bundled demo snapshot, and they are honoured everywhere except a
  production release — because copying a development environment file into a
  release is otherwise indistinguishable from running a demo, and the difference
  is who can read the mirror.

  A production release may still ask for them deliberately: mirroring the demo
  source allows them, and anything else needs `MIRROR_ALLOW_UNSAFE_IDENTITY`.
  """

  @demo_source ConfluencePhxMirror.Confluence.DemoSource

  @doc """
  Whether the shortcuts may be honoured.

  `environment` is `config_env/0`, `source` the configured
  `ConfluencePhxMirror.Confluence.Source`, and `acknowledged?` whether the
  operator set `MIRROR_ALLOW_UNSAFE_IDENTITY`.
  """
  @spec allowed?(atom(), module(), boolean()) :: boolean()
  def allowed?(environment, source, acknowledged?) do
    environment != :prod or source == @demo_source or acknowledged?
  end

  @doc "Whether an environment variable holds an enabling value."
  @spec enabled?(String.t() | nil) :: boolean()
  def enabled?(value), do: value in ~w(1 true yes)

  @doc "The variable an operator sets to allow the shortcuts in production."
  def acknowledgement_variable, do: "MIRROR_ALLOW_UNSAFE_IDENTITY"
end
