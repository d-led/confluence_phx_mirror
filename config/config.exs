# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :confluence_phx_mirror,
  ecto_repos: [ConfluencePhxMirror.Repo],
  generators: [timestamp_type: :utc_datetime]

# Background jobs. Sync work is retried per source page, notification e-mails are
# retried separately so a broken mailer never blocks the mirror.
config :confluence_phx_mirror, Oban,
  repo: ConfluencePhxMirror.Repo,
  queues: [sync: 4, notifications: 10],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: [{"0 * * * *", ConfluencePhxMirror.Notifications.DigestWorker}]}
  ]

# Where the mirrored content comes from. `DemoSource` ships a rich offline
# snapshot so the mirror can be demoed without Confluence credentials; use
# `ConfluencePhxMirror.Confluence.HttpSource` against a real site.
config :confluence_phx_mirror, :source, ConfluencePhxMirror.Confluence.DemoSource

config :confluence_phx_mirror,
  mirror: [name: "Confluence Mirror", tagline: "Read-only, always available"],
  # Blob storage is runtime data, never source: keep it out of priv/static so
  # the mirrored content cannot accidentally be checked in.
  blob_root: "var/mirror",
  # Search paging. The text-search configuration itself (`simple`) is baked into
  # the generated `search_vector` column, so it is not runtime configurable.
  search: [page_size: 30, default_limit: 25, max_limit: 100],
  # Passwordless sign-in links.
  accounts: [login_token_minutes: 15],
  # How far back an incremental pull starts when the source has no cursor.
  sync: [lookback_seconds: 3600, personal_spaces: false],
  # Simulated / production users get auto-provisioned in dev and test.
  auto_admin: false,
  self_signup: false,
  # Administration: the `admin` role, membership of these groups, or these
  # seeded e-mails (CM_ADMINS). Groups come from mirrored Confluence groups.
  admins: [],
  admin_groups: ["confluence-admins"],
  # Accounts are provisioned by the reverse proxy's identity header when
  # enabled; the endpoint must then only be reachable through that proxy.
  proxy_auth: false,
  proxy_auth_header: "x-forwarded-email",
  proxy_auth_name_header: "x-forwarded-user",
  # Extra skins for the theme picker. Built-in skins (system/light/mirror/dark)
  # are always available; the shape is documented in ConfluencePhxMirrorWeb.Skins.
  skins: [],
  reader_rate_limit: [
    enabled: true,
    html: [limit: 240, period_ms: 60_000],
    api: [limit: 120, period_ms: 60_000],
    attachments: [limit: 300, period_ms: 60_000]
  ],
  notifications: [
    enabled: true,
    from: {"Confluence Mirror", "mirror@localhost"},
    digest_hour_utc: 8
  ],
  webhooks: [secret: nil, require_signature: true]

# HTTP client defaults; runtime.exs overrides them from CM_* variables.
config :confluence_phx_mirror, ConfluencePhxMirror.Confluence.HttpSource,
  retries: 3,
  page_size: 50,
  retry_backoff_ms: 250

# Configure the endpoint
config :confluence_phx_mirror, ConfluencePhxMirrorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ConfluencePhxMirrorWeb.ErrorHTML, json: ConfluencePhxMirrorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ConfluencePhxMirror.PubSub,
  live_view: [signing_salt: "dYirs6W3"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :confluence_phx_mirror, ConfluencePhxMirror.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  confluence_phx_mirror: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  confluence_phx_mirror: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :reason,
    :job_id,
    :user,
    :sync_run_id,
    :mode,
    :source,
    :status,
    :pages,
    :attachments,
    :errors
  ]

# Use Elixir's built-in JSON codec (Elixir 1.18+); no Jason dependency.
config :phoenix, :json_library, JSON

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
