import Config

# The desktop export tool. Everything it writes lives under the user's data
# directory, never in the checkout: an installed app has no writable `var/`, and
# a user's content does not belong beside the source.
data_dir = :filename.basedir(:user_data, "confluence-export")
File.mkdir_p!(data_dir)

# No password hasher in this build. `argon2_elixir` has no Windows build at all
# (its Makefile has no Windows branch), and the tool has to ship there, so
# `mix.exs` leaves it out of `:desktop`. What that costs is written down once:
# `Accounts.TokenHash.Hasher` stores a word instead of a digest and refuses every
# digest it cannot compute. The tool issues no tokens — one local reader, no
# sign-in, no API clients.
config :confluence_phx_mirror, :password_hasher, nil

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
# folder is fixed (this one), and the file beside it records only which site the
# workspace mirrors — so these are what `mix ecto.*` sees before the tool has
# started.
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

# The window is the whole of this deployment's boundary: a loopback listener, one
# reader, and no sign-in to give that reader. `AutoAdmin` is what makes that
# reader an administrator, which is what puts the cockpit — settings, spaces,
# jobs, users — one click from the mirror the window opens on. A release that
# mirrors somebody else's site refuses to start with this on
# (`ConfluencePhxMirror.Config.IdentityGuard`), and the tool is not a release
# that mirrors somebody else's site: it mirrors the one the folder holds.
#
# `:desktop_tool` is how the server's own layout knows to offer the tool's
# screen. Absent, nothing renders and the server is unchanged.
config :confluence_phx_mirror,
  auto_admin: true,
  auto_admin_email: "you@localhost",
  desktop_tool: true

# Sessions. A release takes the signing salt from `SECRET_KEY_BASE` because it
# has a deployment to get one from; the tool has none, and a constant here would
# be a secret in a repository. `Desktop.Application` generates one per launch
# instead — the window is one reader on loopback, and the session it signs is the
# one this process is serving (`:auto_admin` establishes the reader again on the
# next request, so there is nothing to keep across a restart).

# The jobs the server queues are how an administrator starts a sync. SQLite is
# not Postgres, and Oban has an engine for it; the queues are one process each
# because there is one writer and one reader, and fourteen consumers on one
# SQLite connection would spend their time queueing for it.
config :confluence_phx_mirror, Oban,
  engine: Oban.Engines.Lite,
  queues: [sync: 1, notifications: 1]

config :logger, level: :info
