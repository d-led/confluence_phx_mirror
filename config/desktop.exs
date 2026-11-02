import Config

# The desktop export tool. Everything it writes lives under the user's data
# directory, never in the checkout: an installed app has no writable `var/`, and
# a user's content does not belong beside the source.
data_dir = :filename.basedir(:user_data, "confluence-export")
File.mkdir_p!(data_dir)

config :confluence_phx_mirror,
  ecto_repos: [ConfluencePhxMirror.Repo],
  # Fixed at compile time by `ConfluencePhxMirror.Repo`. dev, test and prod never
  # set it, so they keep building the same module on Postgres.
  repo_adapter: Ecto.Adapters.SQLite3,
  # The columns Postgres stores as `text[]`: JSON text here. The schemas read
  # these two keys when they compile, so a list column and its storage agree.
  string_list_type: ConfluencePhxMirror.Schema.JSONList,
  integer_list_type: ConfluencePhxMirror.Schema.JSONList

# Defaults only. `ConfluencePhxMirror.Desktop.Settings` owns the real answer — the
# folder a person picks is written to a settings file and read before the repo
# starts — so these are what a fresh install uses, and what `mix ecto.*` sees.
config :confluence_phx_mirror, ConfluencePhxMirror.Repo,
  database: Path.join(data_dir, "catalogue.db"),
  journal_mode: :wal,
  # One connection. SQLite has one writer, the ingest is the only writer, and a
  # pool that allowed a second connection would only find the lock later.
  pool_size: 1

# Attachments, as files, under the same folder. `LocalStore` is a module behind
# this dispatch, not a process, so nothing extra is supervised. `Paths` sets both
# keys again at boot, from wherever the person put their data.
config :confluence_phx_mirror, :blob_store, ConfluencePhxMirror.Blobs.LocalStore
config :confluence_phx_mirror, :blob_root, Path.join(data_dir, "blobs")

# The tool sends no mail. Without this, Swoosh resolves Hackney at start-up —
# a dependency the application does not have — and the release will not boot.
# dev and test disable it for the same reason.
config :swoosh, api_client: false

config :logger, level: :info
