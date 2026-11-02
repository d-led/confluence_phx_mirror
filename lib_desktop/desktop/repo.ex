defmodule ConfluencePhxMirror.Desktop.Repo do
  @moduledoc """
  The export tool's store: one SQLite file in the user's data directory.

  It shares nothing with `ConfluencePhxMirror.Repo` but the application it is
  configured under. No module in `lib/` names this one, and no release the
  server builds compiles this file — `:desktop` is the only environment whose
  `elixirc_paths/1` includes `lib_desktop/`.

  The path comes from `Desktop.Settings` when the repo starts, not from
  configuration, because the folder is chosen in the UI. `mix ecto.*` tasks do
  not go through this callback and see the configured default instead.
  """

  use Ecto.Repo,
    otp_app: :confluence_phx_mirror,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    database = ConfluencePhxMirror.Desktop.Settings.database()
    File.mkdir_p!(Path.dirname(database))

    {:ok, Keyword.put(config, :database, database)}
  end
end
