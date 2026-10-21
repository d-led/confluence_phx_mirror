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
  {site, token}
  when is_binary(site) and site != "" and is_binary(token) and token != "" ->
    ConfluencePhxMirror.Confluence.HttpSource

  _no_credentials ->
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
# unset, configured credentials (`CM_CONFLUENCE_SITE` plus `CM_ATL_TOKEN`) mean
# the real thing — a deployment that has them should not silently mirror
# fixtures — and otherwise the demo snapshot keeps the app usable.
source =
  case {System.get_env("CM_SOURCE"), config_env()} do
    {"http", _env} ->
      ConfluencePhxMirror.Confluence.HttpSource

    {"live", _env} ->
      ConfluencePhxMirror.Confluence.HttpSource

    {"demo", _env} ->
      ConfluencePhxMirror.Confluence.DemoSource

    # The suite must never reach for a real site because a developer happens to
    # export credentials: tests use the demo snapshot unless told otherwise.
    {nil, :test} ->
      ConfluencePhxMirror.Confluence.DemoSource

    {_unset, _env} ->
      default_source.({System.get_env("CM_CONFLUENCE_SITE"), System.get_env("CM_ATL_TOKEN")})
  end

config :confluence_phx_mirror, :source, source

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
           String.to_integer(System.get_env("CM_SYNC_INTERVAL_SECONDS", "900"))
       )

if blob_root = System.get_env("MIRROR_BLOB_ROOT") do
  config :confluence_phx_mirror, blob_root: blob_root
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

if header = System.get_env("CM_PROXY_AUTH_HEADER") do
  config :confluence_phx_mirror, :proxy_auth_header, String.downcase(header)
end

if header = System.get_env("CM_PROXY_AUTH_NAME_HEADER") do
  config :confluence_phx_mirror, :proxy_auth_name_header, String.downcase(header)
end

if webhook_secret = System.get_env("CM_WEBHOOK_SECRET") do
  config :confluence_phx_mirror,
    webhooks: [
      secret: webhook_secret,
      require_signature: System.get_env("CM_WEBHOOK_REQUIRE_SIGNATURE", "true") in ~w(1 true yes)
    ]
end

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

  config :confluence_phx_mirror, ConfluencePhxMirror.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
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
