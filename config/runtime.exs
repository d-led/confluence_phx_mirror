import Config

# Integer tuning knobs fall back to the compiled defaults in config.exs.
env_integer = fn name, default ->
  case System.get_env(name) do
    nil -> default
    value -> String.to_integer(value)
  end
end

csv = fn value ->
  value
  |> String.split(",", trim: true)
  |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  |> Enum.reject(&(&1 == ""))
end

default_source = fn
  {site, email, token}
  when is_binary(site) and site != "" and is_binary(email) and email != "" and
         is_binary(token) and token != "" ->
    ConfluencePhxMirror.Confluence.HttpSource

  _missing_credentials ->
    ConfluencePhxMirror.Confluence.DemoSource
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/confluence_phx_mirror start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :confluence_phx_mirror, ConfluencePhxMirrorWeb.Endpoint, server: true
end

# --- Mirror source -----------------------------------------------------------
#
# `CM_SOURCE` picks the upstream explicitly: `demo` mirrors the bundled sample
# snapshot, `http` reads a real Confluence site through its REST API. Left
# unset, a complete set of credentials (`CM_CONFLUENCE_SITE`, `CM_ATL_EMAIL`,
# `CM_ATL_TOKEN`) means the real thing — a deployment that has them should not
# silently mirror fixtures — and otherwise the demo snapshot keeps the app
# usable.
source =
  case {System.get_env("CM_SOURCE"), config_env()} do
    {"http", _env} ->
      ConfluencePhxMirror.Confluence.HttpSource

    {"live", _env} ->
      ConfluencePhxMirror.Confluence.HttpSource

    {"demo", _env} ->
      ConfluencePhxMirror.Confluence.DemoSource

    {"synthetic", _env} ->
      ConfluencePhxMirror.Confluence.SyntheticSource

    # The suite must never reach for a real site because a developer happens to
    # export credentials: tests use the demo snapshot unless told otherwise.
    {nil, :test} ->
      ConfluencePhxMirror.Confluence.DemoSource

    {_unset, _env} ->
      default_source.({
        System.get_env("CM_CONFLUENCE_SITE"),
        System.get_env("CM_ATL_EMAIL"),
        System.get_env("CM_ATL_TOKEN")
      })
  end

config :confluence_phx_mirror, :source, source

# --- Generated content -------------------------------------------------------
#
# `CM_SOURCE=synthetic` mirrors generated spaces and pages instead of a site.
# They are a fixture: the reader UI says so, the site key keeps their database
# apart from a real mirror's, and the sizes are what a measurement asks for.
# Ingesting them goes through the ordinary sync, one page at a time — see
# "Reading at scale" in docs/developers.md for the fast path a test uses.
document_counts =
  Application.get_env(:confluence_phx_mirror, ConfluencePhxMirror.Confluence.SyntheticSource, [])

config :confluence_phx_mirror,
       ConfluencePhxMirror.Confluence.SyntheticSource,
       Keyword.merge(document_counts,
         spaces: String.to_integer(System.get_env("CM_SYNTHETIC_SPACES", "10")),
         pages_per_space: String.to_integer(System.get_env("CM_SYNTHETIC_PAGES", "100")),
         branching: String.to_integer(System.get_env("CM_SYNTHETIC_BRANCHING", "10"))
       )

# --- Site isolation ----------------------------------------------------------
#
# A mirror instance shows exactly one site, and each site gets its own database,
# so demo fixtures can never be mistaken for mirrored content (or the other way
# round). In development the database name is derived from the configured site:
# `..._demo` for the bundled snapshot, `..._dled_atlassian_net` for a real one.
# Deployments set DATABASE_URL and stay in charge of their own database.
if config_env() == :dev and System.get_env("DATABASE_URL") in [nil, ""] do
  site_key =
    case source do
      ConfluencePhxMirror.Confluence.DemoSource ->
        "demo"

      ConfluencePhxMirror.Confluence.SyntheticSource ->
        "synthetic"

      _live ->
        ConfluencePhxMirror.Sites.key_for(System.get_env("CM_CONFLUENCE_SITE"))
    end

  repo = Application.get_env(:confluence_phx_mirror, ConfluencePhxMirror.Repo, [])
  base = Keyword.get(repo, :database, "confluence_phx_mirror_dev")

  config :confluence_phx_mirror,
         ConfluencePhxMirror.Repo,
         Keyword.put(repo, :database, ConfluencePhxMirror.Sites.database(base, site_key))
end

http_defaults =
  Application.get_env(:confluence_phx_mirror, ConfluencePhxMirror.Confluence.HttpSource, [])

config :confluence_phx_mirror,
       ConfluencePhxMirror.Confluence.HttpSource,
       Keyword.merge(http_defaults,
         # Pages a run reads and writes at once. Each one holds a database
         # connection for the length of its own transaction, so this is also
         # how hard a re-read leans on Postgres: a shared-CPU database is
         # happier at 2 than at 4 (see "A re-read, sized" in
         # docs/operations.md).
         sync_concurrency: String.to_integer(System.get_env("CM_SYNC_CONCURRENCY") || "4"),
         base_url: System.get_env("CM_CONFLUENCE_SITE"),
         email: System.get_env("CM_ATL_EMAIL"),
         api_token: System.get_env("CM_ATL_TOKEN"),
         requests_per_second: String.to_integer(System.get_env("CM_REQUESTS_PER_SECOND", "5")),
         burst: String.to_integer(System.get_env("CM_BURST", "5")),
         retries: String.to_integer(System.get_env("CM_HTTP_RETRIES", "3")),
         page_size: String.to_integer(System.get_env("CM_HTTP_PAGE_SIZE", "50")),
         retry_backoff_ms: String.to_integer(System.get_env("CM_HTTP_RETRY_BACKOFF_MS", "250")),
         spaces:
           case System.get_env("CM_SPACES") do
             nil -> :all
             "" -> :all
             keys -> keys |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
           end,
         sync_interval_seconds:
           String.to_integer(System.get_env("CM_SYNC_INTERVAL_SECONDS", "3600")),
         # Pages that changed are detailed (attachments, comments) this many at a
         # time; the request rate limit still paces the actual calls.
         sync_concurrency: String.to_integer(System.get_env("CM_SYNC_CONCURRENCY", "4"))
       )

if blob_root = System.get_env("MIRROR_BLOB_ROOT") do
  config :confluence_phx_mirror, blob_root: blob_root
end

if stats_refresh = System.get_env("CM_ADMIN_STATS_REFRESH_SECONDS") do
  config :confluence_phx_mirror, admin_stats_refresh_seconds: String.to_integer(stats_refresh)
end

# Postgres reports what it uses and never what is left — no SQL function reaches
# statvfs — so the database figure gets a percentage only when the size of its
# volume is known. On Fly that is the volume's own size (`fly volumes list`).
if capacity = System.get_env("CM_DATABASE_CAPACITY_GB") do
  config :confluence_phx_mirror, database_capacity_bytes: String.to_integer(capacity) * 1024 ** 3
end

# The three switch columns from here on hand out identity without a sign-in.
# They belong to development and to the bundled demo, so a production release
# that mirrors a real site refuses to start with them on rather than quietly
# serving the mirror to whoever visits. `MIRROR_ALLOW_UNSAFE_IDENTITY` is the
# acknowledgement for a deliberate demo in a release; the demo source needs none.
unsafe_identity_env = [
  {"MIRROR_AUTO_ADMIN", System.get_env("MIRROR_AUTO_ADMIN")},
  {"MIRROR_SELF_SIGNUP", System.get_env("MIRROR_SELF_SIGNUP")},
  {"CM_PROXY_AUTH", System.get_env("CM_PROXY_AUTH")}
]

acknowledged? =
  ConfluencePhxMirror.Config.IdentityGuard.enabled?(
    System.get_env(ConfluencePhxMirror.Config.IdentityGuard.acknowledgement_variable())
  )

requested =
  for {name, value} <- unsafe_identity_env,
      ConfluencePhxMirror.Config.IdentityGuard.enabled?(value),
      do: name

if requested != [] and
     not ConfluencePhxMirror.Config.IdentityGuard.allowed?(config_env(), source, acknowledged?) do
  raise """
  #{Enum.join(requested, ", ")} hands out an identity without a sign-in, and this
  release mirrors #{inspect(source)} in production.

  The mirror refuses to start rather than serve itself to every visitor.
  To run the demo in a release, set CM_SOURCE=demo (the demo source needs no
  acknowledgement). To insist, set #{ConfluencePhxMirror.Config.IdentityGuard.acknowledgement_variable()}=1.
  """
end

if auto_admin = System.get_env("MIRROR_AUTO_ADMIN") do
  config :confluence_phx_mirror, auto_admin: auto_admin in ~w(1 true yes)
end

if self_signup = System.get_env("MIRROR_SELF_SIGNUP") do
  config :confluence_phx_mirror, self_signup: self_signup in ~w(1 true yes)
end

# CM_ADMINS="ops@acme.com,lead@acme.com" seeds administrators by e-mail, and
# CM_ADMIN_GROUPS="site-admins" decides which mirrored group grants admin.
if admins = System.get_env("CM_ADMINS") do
  config :confluence_phx_mirror, :admins, csv.(admins)
end

if admin_groups = System.get_env("CM_ADMIN_GROUPS") do
  config :confluence_phx_mirror, :admin_groups, csv.(admin_groups)
end

# CM_PROXY_AUTH=true trusts the identity header set by a reverse proxy (e.g.
# oauth2-proxy) and provisions accounts from it.
if proxy_auth = System.get_env("CM_PROXY_AUTH") do
  config :confluence_phx_mirror, :proxy_auth, proxy_auth in ~w(1 true yes)
end

# A reader Confluence switched off is refused by the mirror too: the site
# decides who may read it. MIRROR_ALLOW_SITE_DISABLED_READERS=1 relaxes that for
# a mirror meant to outlive an account being stood down — the content stays
# readable while the person is inactive on the site. Accounts the site no longer
# has, and accounts banned here, are refused either way.
if allow = System.get_env("MIRROR_ALLOW_SITE_DISABLED_READERS") do
  config :confluence_phx_mirror, allow_site_disabled_readers: allow in ~w(1 true yes)
end

if header = System.get_env("CM_PROXY_AUTH_HEADER") do
  config :confluence_phx_mirror, :proxy_auth_header, String.downcase(header)
end

if header = System.get_env("CM_PROXY_AUTH_NAME_HEADER") do
  config :confluence_phx_mirror, :proxy_auth_name_header, String.downcase(header)
end

# An OAuth2 proxy usually sits in front of a whole Atlassian organisation, which
# is wider than the site being mirrored. By default the mirror therefore admits
# only administrators and identities the sync has seen on that site;
# CM_PROXY_AUTH_MEMBERS_ONLY=false restores "whoever the proxy admits".
if members_only = System.get_env("CM_PROXY_AUTH_MEMBERS_ONLY") do
  config :confluence_phx_mirror, :proxy_auth_members_only, members_only in ~w(1 true yes)
end

# Who counts as a reader: a policy, not a switch. `CM_USER_POLICY` names one of
# the shipped policies; an unknown name raises rather than falling back, because
# a typo must not quietly widen or narrow the audience. Without it, the switches
# above decide (`CM_PROXY_AUTH_MEMBERS_ONLY`, `self_signup`).
if policy = System.get_env("CM_USER_POLICY") do
  config :confluence_phx_mirror,
         :user_policy,
         ConfluencePhxMirror.Accounts.UserPolicy.named!(policy)
end

# An identity provider in front of the proxy may assert group names; naming the
# header here is what lets a policy check them against the mirrored membership.
if header = System.get_env("CM_PROXY_AUTH_GROUPS_HEADER") do
  config :confluence_phx_mirror, :proxy_auth_groups_header, String.downcase(header)
end

# Webhooks accept unsigned deliveries by default: a mirror that has just been
# pointed at a Confluence site should work, and /admin/webhooks keeps saying what
# that costs. `CM_WEBHOOK_SECRET` plus `CM_WEBHOOK_REQUIRE_SIGNATURE=true` closes
# the intake; an administrator can also flip it on that page, which overrides
# this without a restart.
#
# The secret is only replaced when the variable is set, so the development and
# test secrets configured elsewhere survive a boot.
webhooks =
  :confluence_phx_mirror
  |> Application.get_env(:webhooks, [])
  |> Keyword.put(
    :require_signature,
    System.get_env("CM_WEBHOOK_REQUIRE_SIGNATURE", "false") in ~w(1 true yes)
  )

webhooks =
  case System.get_env("CM_WEBHOOK_SECRET") do
    nil -> webhooks
    secret -> Keyword.put(webhooks, :secret, secret)
  end

# The intake can also be switched off altogether — for a mirror that has no
# reason to be reachable by the site, because it sits behind a sign-in proxy or
# because its sync is scheduled. Off means every delivery is answered `410 Gone`
# and nothing is stored. Only a variable that is set overrides the default, so a
# development or test configuration survives a boot.
webhooks =
  case System.get_env("CM_WEBHOOK_ENABLED") do
    nil -> webhooks
    value -> Keyword.put(webhooks, :enabled, value in ~w(1 true yes))
  end

config :confluence_phx_mirror, webhooks: webhooks

# CM_THEME seeds the theme the whole site wears ("fresh-blue" ships with the
# mirror). An administrator changes it on the settings page; readers pick only
# light, dark or system. A misspelt name stops the release at boot.
if theme = System.get_env("CM_THEME") do
  config :confluence_phx_mirror, theme: theme
end

# The API description and its page: `/api/openapi.json` and `/api/docs`. Served
# in development and test because they cost nothing and help while building
# against the mirror; a release has to ask for them, so a deployment never grows
# a surface it did not choose. CM_API_DOCS=1 (or 0) decides either way.
api_docs =
  case System.get_env("CM_API_DOCS") do
    nil -> config_env() != :prod
    value -> value in ~w(1 true yes on)
  end

config :confluence_phx_mirror, api_docs: api_docs

config :confluence_phx_mirror,
  notifications: [
    enabled: System.get_env("MIRROR_NOTIFICATIONS", "true") in ~w(1 true yes),
    from:
      {System.get_env("MIRROR_MAIL_FROM_NAME", "Confluence Mirror"),
       System.get_env("MIRROR_MAIL_FROM", "mirror@localhost")},
    digest_hour_utc: String.to_integer(System.get_env("MIRROR_DIGEST_HOUR_UTC", "8"))
  ]

if rate_limit =
     System.get_env("CM_READER_RATE_LIMIT_PER_MINUTE") ||
       System.get_env("MIRROR_READER_RATE_LIMIT_PER_MINUTE") do
  per_minute = String.to_integer(rate_limit)

  html = env_integer.("CM_RATE_LIMIT_HTML_PER_MINUTE", per_minute)
  api = env_integer.("CM_RATE_LIMIT_API_PER_MINUTE", max(div(per_minute, 2), 1))
  attachments = env_integer.("CM_RATE_LIMIT_ATTACHMENTS_PER_MINUTE", per_minute * 2)

  config :confluence_phx_mirror,
    reader_rate_limit: [
      enabled: html > 0 or api > 0 or attachments > 0,
      html: [limit: html, period_ms: 60_000],
      api: [limit: api, period_ms: 60_000],
      attachments: [limit: attachments, period_ms: 60_000]
    ]
end

# Behind a reverse proxy every reader shares the proxy's address, so the reader
# rate limit would throttle the whole site at once. Trust `X-Forwarded-For` when
# the mirror only accepts traffic from that proxy.
if System.get_env("CM_TRUST_PROXY_HEADERS", "false") in ~w(1 true yes) do
  config :confluence_phx_mirror, trust_proxy_headers: true
end

# The webhook intake always keeps a per-client cap: a delivery is stored before
# its signature is checked, so this is the only limit that must not be off.
if webhook_limit = System.get_env("CM_WEBHOOK_RATE_LIMIT_PER_MINUTE") do
  config :confluence_phx_mirror,
    webhook_rate_limit: [limit: String.to_integer(webhook_limit), period_ms: 60_000]
end

# CM_WEBHOOK_TOKENS="confluence=s3cret,backup=other-secret" authenticates
# webhook deliveries with a fixed token instead of an HMAC signature. The token
# only works on the webhook route.
if tokens = System.get_env("CM_WEBHOOK_TOKENS") do
  config :confluence_phx_mirror,
    webhook_tokens:
      Map.new(String.split(tokens, ",", trim: true), fn pair ->
        [receiver, token] = String.split(pair, "=", parts: 2)
        {String.trim(receiver), String.trim(token)}
      end)
end

search_defaults = Application.get_env(:confluence_phx_mirror, :search, [])

config :confluence_phx_mirror,
       :search,
       Keyword.merge(search_defaults,
         page_size:
           env_integer.("CM_SEARCH_PAGE_SIZE", Keyword.get(search_defaults, :page_size, 30)),
         default_limit:
           env_integer.(
             "CM_SEARCH_DEFAULT_LIMIT",
             Keyword.get(search_defaults, :default_limit, 25)
           ),
         max_limit:
           env_integer.("CM_SEARCH_MAX_RESULTS", Keyword.get(search_defaults, :max_limit, 100))
       )

accounts_defaults = Application.get_env(:confluence_phx_mirror, :accounts, [])

config :confluence_phx_mirror,
       :accounts,
       Keyword.merge(accounts_defaults,
         login_token_minutes:
           env_integer.(
             "CM_LOGIN_TOKEN_MINUTES",
             Keyword.get(accounts_defaults, :login_token_minutes, 15)
           )
       )

sync_defaults = Application.get_env(:confluence_phx_mirror, :sync, [])

config :confluence_phx_mirror,
       :sync,
       Keyword.merge(sync_defaults,
         lookback_seconds:
           env_integer.(
             "CM_SYNC_LOOKBACK_SECONDS",
             Keyword.get(sync_defaults, :lookback_seconds, 3600)
           ),
         personal_spaces:
           System.get_env("CM_SYNC_PERSONAL_SPACES", "false") in ["true", "1", "yes"],
         detail_backlog:
           env_integer.(
             "CM_SYNC_DETAIL_BACKLOG",
             Keyword.get(sync_defaults, :detail_backlog, 200)
           )
       )

if smtp_relay = System.get_env("SMTP_RELAY") do
  config :confluence_phx_mirror, ConfluencePhxMirror.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_relay,
    port: String.to_integer(System.get_env("SMTP_PORT", "587")),
    username: System.get_env("SMTP_USERNAME"),
    password: System.get_env("SMTP_PASSWORD"),
    tls: if(System.get_env("SMTP_TLS", "always") in ~w(never false 0), do: :never, else: :always),
    auth:
      if(System.get_env("SMTP_AUTH", "always") in ~w(never false 0), do: :never, else: :always)
end

config :confluence_phx_mirror, ConfluencePhxMirrorWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :confluence_phx_mirror, ConfluencePhxMirrorWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/confluence_phx_mirror_web/router\.ex$"E,
        ~r"lib/confluence_phx_mirror_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  pool_size = String.to_integer(System.get_env("POOL_SIZE") || "20")
  pool_count = String.to_integer(System.get_env("POOL_COUNT") || "1")

  config :confluence_phx_mirror, ConfluencePhxMirror.Repo,
    # ssl: true,
    url: database_url,
    # Connections this replica opens: pool_count × pool_size. The deployment's
    # total is replicas × that, and it has to fit Postgres' max_connections —
    # see "Sizing the connection pool" in docs/operations.md.
    pool_size: pool_size,
    # One pool per batch of schedulers spreads contention on machines with many
    # cores (each pool has its own queue); leave at 1 unless measured otherwise.
    pool_count: pool_count,
    # Checkout timeout, in milliseconds. A reader waits for a connection rather
    # than failing; the queue knobs in config/config.exs decide when the pool
    # starts pushing back.
    timeout: String.to_integer(System.get_env("POOL_TIMEOUT_MS") || "15000"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :confluence_phx_mirror, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :confluence_phx_mirror, ConfluencePhxMirrorWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :confluence_phx_mirror, ConfluencePhxMirrorWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :confluence_phx_mirror, ConfluencePhxMirrorWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :confluence_phx_mirror, ConfluencePhxMirror.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
