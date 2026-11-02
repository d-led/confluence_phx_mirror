defmodule ConfluencePhxMirror.Repo do
  @moduledoc """
  The application's store.

  One repo module for both deployments. `use Ecto.Repo` fixes the adapter into
  the code it generates, so the adapter is chosen when an environment *compiles*
  rather than when it runs: the server builds with Postgres, and `MIX_ENV=desktop`
  builds this same module with SQLite. That is what lets every context, query and
  view in `lib/` stay exactly as it is — the desktop tool runs the server's own
  code against a different adapter instead of a second copy of it.

  Where the database is, is configuration like any other. The folder is chosen in
  the tool's UI, so `Desktop.Settings` writes the path at boot, before the repo
  starts.
  """

  @adapter Application.compile_env(:confluence_phx_mirror, :repo_adapter, Ecto.Adapters.Postgres)

  use Ecto.Repo,
    otp_app: :confluence_phx_mirror,
    adapter: @adapter
end
