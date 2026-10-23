import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :confluence_phx_mirror, ConfluencePhxMirror.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "confluence_phx_mirror_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :confluence_phx_mirror, ConfluencePhxMirrorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "LJ4dfhf+oxVOz5DXoeVutkPU2KhuMpYsFInNzIWQeOgF5xRHeayQfrtjuBVLX1w7",
  server: false

# In test we don't send emails, we assert on them
config :confluence_phx_mirror, ConfluencePhxMirror.Mailer, adapter: Swoosh.Adapters.Test

# Oban runs manually in tests: each test drives the jobs it cares about.
# See https://hexdocs.pm/oban/testing.html
config :confluence_phx_mirror, Oban,
  testing: :manual,
  queues: false,
  plugins: false

config :confluence_phx_mirror,
  auto_admin: true,
  self_signup: true,
  blob_root: "tmp/mirror_test",
  # Argon2 is memory-hard on purpose; the suite pays for the algorithm, not for
  # the production cost of it (16 MiB and two passes per token check).
  token_hash_params: [t_cost: 1, m_cost: 3, parallelism: 1],
  reader_rate_limit: [
    enabled: true,
    html: [limit: 1_000, period_ms: 60_000],
    api: [limit: 1_000, period_ms: 60_000],
    attachments: [limit: 1_000, period_ms: 60_000]
  ],
  notifications: [enabled: true, from: {"Mirror", "mirror@localhost"}, digest_hour_utc: 8],
  webhooks: [secret: "test-webhook-secret", require_signature: false]

config :confluence_phx_mirror, ConfluencePhxMirror.Confluence.DemoSource,
  sync_interval_seconds: 0,
  # The SQL sandbox hands a test one connection, so detailing pages in
  # parallel here would just queue behind it. Production reads this from
  # `CM_SYNC_CONCURRENCY`.
  sync_concurrency: 1

# Tests talk to stubbed HTTP transports, so the client-side pacing must not turn
# a unit test into a minute-long wait.
config :confluence_phx_mirror, ConfluencePhxMirror.Confluence.HttpSource,
  requests_per_second: 1_000,
  burst: 1_000

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
