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

# The pool is DBConnection's (`Ecto.Adapters.Postgres` → Postgrex →
# `DBConnection.ConnectionPool`), so its queue tuning applies here. The defaults
# (queue_target: 50, queue_interval: 1000) treat a 50 ms wait as a sign that the
# pool is too small and start shedding requests soon after — which is right for a
# server that must stay responsive and wrong for a read-only mirror, where a
# reader waiting 300 ms beats a reader getting a 500. `pool_size` itself comes
# from `POOL_SIZE` (config/runtime.exs): this only decides how patiently the pool
# waits.
config :confluence_phx_mirror, ConfluencePhxMirror.Repo,
  queue_target: 200,
  queue_interval: 2_000

# Background jobs. Sync work is retried per source page, notification e-mails are
# retried separately so a broken mailer never blocks the mirror.
#
# Three of Oban's built-in plugins are configured by name here, which is why
# they are keys and not entries in `plugins:`.
#
# `pruner` — a finished job is the only per-job evidence a sweep leaves behind
# ("space LOAD431: done, 935 pages"), and the queue's default is to delete one a
# minute after it ends, so the jobs page would only ever show work in flight.
# A day is long enough to read what ran overnight and short enough to stay a few
# thousand rows. The durable record is still `sync_runs`, one row per run.
#
# `lifeline` — what keeps the queue honest when a node dies mid-job: without it
# a job whose process disappeared stays `executing` for ever, nothing retries it
# and `/admin/jobs` keeps listing work that nobody is doing. A restarted machine
# (a deploy, an OOM kill) is exactly how a long sync ends, so the rescuer is not
# optional here.
#
# `rescue_after` is how long a job may look silent before it counts as orphaned,
# so it has to be longer than the longest legitimate run. Half an hour is not:
# first listing of a site this size takes well over one (123k pages at ~20 a
# second), and the rescuer retried a run that was working perfectly well — the
# retry found the sync gate held, said so, and left the job row `completed` with
# no attempts left while the real run went on. Six hours is past any run this
# mirror has done; the per-space marker (`spaces.pages_listed_at`) means an
# interruption resumes instead of restarting, so waiting longer costs nothing.
config :confluence_phx_mirror, Oban,
  repo: ConfluencePhxMirror.Repo,
  queues: [sync: 4, notifications: 10],
  pruner: [max_age: {1, :day}],
  lifeline: [rescue_after: :timer.hours(6)],
  cron: [crontab: [{"0 * * * *", ConfluencePhxMirror.Notifications.DigestWorker}]]

# Where the mirrored content comes from. `DemoSource` ships a rich offline
# snapshot so the mirror can be demoed without Confluence credentials; use
# `ConfluencePhxMirror.Confluence.HttpSource` against a real site.
config :confluence_phx_mirror, :source, ConfluencePhxMirror.Confluence.DemoSource

# The whole-site static export is a file that leaves the building, so it carries
# the spaces everybody shares and not the personal ones — somebody's drafts and
# notes are not part of "the site". `CM_EXPORT_PERSONAL_SPACES=1` turns them on
# for a mirror whose personal spaces are meant to travel; a single space is
# still exportable on its own either way.
config :confluence_phx_mirror, export_personal_spaces: false

# Themes beyond the built-in default ship as standalone packs: modules
# implementing `ConfluencePhxMirrorWeb.Skins.Pack`. `FreshBlue` is the reference
# extension and the theme the mirror ships with.
config :confluence_phx_mirror, :skin_packs, [ConfluencePhxMirrorWeb.Skins.FreshBlue]

# The theme the whole site wears. An administrator changes it on the settings
# page (stored in the `settings` table); this line only seeds it, and `CM_THEME`
# overrides the seed in a release. Readers pick light, dark or system in the
# header — never the theme itself.
config :confluence_phx_mirror, theme: "fresh-blue"

config :confluence_phx_mirror,
  mirror: [
    name: "Confluence Mirror",
    tagline: "Read-only, always available",
    # Where this software lives. The footer links to it with the GitHub mark; unset
    # (or a fork that renames itself) simply drops the link.
    repo: "https://github.com/d-led/confluence_phx_mirror"
  ],
  # Blob storage is runtime data, never source: keep it out of priv/static so
  # the mirrored content cannot accidentally be checked in.
  blob_root: "var/mirror",
  # Search paging. The text-search configuration itself (`simple`) is baked into
  # the generated `search_vector` column, so it is not runtime configurable.
  search: [page_size: 30, default_limit: 25, max_limit: 100],
  # Passwordless sign-in links.
  accounts: [login_token_minutes: 15],
  # How far back an incremental pull starts when the source has no cursor.
  sync: [lookback_seconds: 3600, personal_spaces: false, detail_backlog: 200],
  # How often an open admin overview re-reads its totals, the run table and the
  # resource figures. The run in flight has its own five-second cadence: this is
  # the slower one, because a mirror's totals do not move between heartbeats.
  # `CM_ADMIN_STATS_REFRESH_SECONDS` overrides it.
  admin_stats_refresh_seconds: 30,
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
  # The proxy says who the caller is; this says whether the mirror wants them.
  # Only an administrator, or an identity the sync has seen on the mirrored
  # site, is admitted; `false` restores "the proxy decides".
  proxy_auth_members_only: true,
  # Who may have an account: nil keeps what the switches above imply, a module
  # (or `{:any_of, [...]}`) is the deployment's own answer. See
  # `ConfluencePhxMirror.Accounts.UserPolicy`.
  user_policy: nil,
  # A header carrying group names an identity provider asserts, if any.
  proxy_auth_groups_header: nil,
  # More themes for the admin's picker, on top of the built-in default and the
  # packs. The shape is documented in ConfluencePhxMirrorWeb.Skins.
  skins: [],
  # Deliveries are stored before their signature is checked so a rejected event
  # stays auditable; that intake is therefore always metered, even where the
  # reader limits below are switched off.
  webhook_rate_limit: [limit: 60, period_ms: 60_000],
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
  # The intake accepts unsigned deliveries unless a deployment requires
  # signatures: a mirror that was just pointed at a Confluence site should
  # work, and /admin/webhooks says loudly what that costs. `CM_WEBHOOK_SECRET`
  # plus `CM_WEBHOOK_REQUIRE_SIGNATURE=true` (or the switch on that page) closes
  # it; a route token is accepted either way.
  webhooks: [secret: nil, require_signature: false]

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
  ],
  # Swagger UI, for /api/docs/swagger only. A bundle of its own so the reader
  # pages never download it; esbuild puts the imported stylesheet beside it.
  confluence_phx_mirror_swagger: [
    args:
      ~w(js/swagger.js --bundle --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
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
    :errors,
    :trigger
  ]

# Phoenix logs every request; Fly's health probe is most of them. Its replacement,
# `ConfluencePhxMirrorWeb.Telemetry.RequestLog`, logs one line per request and
# skips the probes.
config :phoenix, :logger, false

# Use Elixir's built-in JSON codec (Elixir 1.18+); no Jason dependency.
config :phoenix, :json_library, JSON

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
