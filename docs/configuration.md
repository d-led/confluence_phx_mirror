# Configuration

Everything the mirror reads from the environment, plus the one compile-free
customisation point (themes). The app is configured only through the environment
(12-factor); this file is the exhaustive list, so keep it honest: if a variable
is read in `config/` or `lib/`, it belongs here.

Configuration is read at boot; a running development server does **not** reload
`config/*.exs` changes. Booleans accept `1`, `true` or `yes`.

## Platform

| Variable | Default | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | – | Postgres connection (required in prod) |
| `SECRET_KEY_BASE` | – | cookies/sessions (required in prod) |
| `PORT` | `4000` | HTTP listen port |
| `PHX_SERVER` | – | set to `true` to make a release serve HTTP |
| `PHX_HOST` | `example.com` | external host for absolute URLs and secure cookies |
| `POOL_SIZE` | `20` | connections per pool (see [sizing](operations.md#sizing-the-connection-pool)) |
| `POOL_COUNT` | `1` | pools per replica (each has its own queue) |
| `POOL_TIMEOUT_MS` | `15000` | how long a request waits for a connection |
| `ECTO_IPV6` | – | `true` makes the repo use `:inet6` |
| `DNS_CLUSTER_QUERY` | – | DNS-based clustering |

## Source and sync

| Variable | Default | Purpose |
| --- | --- | --- |
| `CM_SOURCE` | see below | `demo`, `http` or `synthetic` |
| `CM_CONFLUENCE_SITE` | – | `https://acme.atlassian.net` (with or without `/wiki`) |
| `CM_ATL_EMAIL` / `CM_ATL_TOKEN` | – | API credentials |
| `CM_SYNTHETIC_SPACES` / `CM_SYNTHETIC_PAGES` | `10` / `100` | generated spaces, and pages per space, when `CM_SOURCE=synthetic` |
| `CM_SYNTHETIC_BRANCHING` | `10` | children per page in the generated tree |
| `CM_SPACES` | all | comma-separated space keys |
| `CM_REQUESTS_PER_SECOND` / `CM_BURST` | `5` / `5` | client rate limit (token bucket) |
| `CM_HTTP_RETRIES` | `3` | attempts per Confluence request |
| `CM_HTTP_PAGE_SIZE` | `50` | content page size when paginating |
| `CM_HTTP_RETRY_BACKOFF_MS` | `250` | first retry delay (doubles per attempt) |
| `CM_SYNC_INTERVAL_SECONDS` | `3600` | scheduled pull (`0` disables) |
| `CM_SYNC_LOOKBACK_SECONDS` | `3600` | minimum window for an incremental pull |
| `CM_SYNC_CONCURRENCY` | `4` | changed pages detailed at once |

Scheduled pulls are incremental: they ask Confluence only for content that
changed since the last run, and pages whose version is unchanged are skipped
without being re-rendered or asked for their attachments and comments. A full
re-read is available on demand ("Re-read everything" on the dashboard, or
`mix confluence.sync --mode snapshot`); expect it to cost one request per page
when the site is large.

`CM_SOURCE` is explicit when set (`demo`, `http` — `live` is accepted as an
alias — or `synthetic`). Left unset, a configured `CM_CONFLUENCE_SITE` selects
the real REST source and no site selects the demo snapshot, so a deployment
that has credentials never silently mirrors fixtures.

`synthetic` is for measuring, not for readers: it generates spaces and pages
(`CM_SYNTHETIC_*`) and ingests them through the ordinary sync, so a laptop can
be given a mirror large enough for the reader screens to behave the way they do
in production. Generated content is a fixture — the UI labels it as such and it
gets its own database (`..._synthetic`), so it can never be mistaken for a
mirror of a real site. Populate it once, from empty:

```bash
CM_SOURCE=synthetic CM_SYNTHETIC_SPACES=200 CM_SYNTHETIC_PAGES=500 \
  mix ecto.drop && CM_SOURCE=synthetic mix ecto.setup
```

## Accounts and sign-in

| Variable | Default | Purpose |
| --- | --- | --- |
| `MIRROR_AUTO_ADMIN` | `false` (dev/test `true`) | assume an admin, no sign-in |
| `MIRROR_SELF_SIGNUP` | `false` | allow magic-link sign-up |
| `CM_LOGIN_TOKEN_MINUTES` | `15` | magic-link lifetime |
| `CM_ADMINS` | – | seeded administrator e-mails (CSV) |
| `CM_ADMIN_GROUPS` | `confluence-admins` | mirrored groups that grant admin (CSV) |
| `CM_PROXY_AUTH` | `false` | trust the reverse proxy's identity header |
| `CM_PROXY_AUTH_HEADER` | `x-forwarded-email` | header carrying the reader's e-mail |
| `CM_PROXY_AUTH_NAME_HEADER` | `x-forwarded-user` | header carrying the display name |
| `MIRROR_ALLOW_UNSAFE_IDENTITY` | `false` | acknowledge the three switches above in a production release |

`MIRROR_AUTO_ADMIN`, `MIRROR_SELF_SIGNUP` and `CM_PROXY_AUTH` each hand out an
identity without a sign-in, so they belong to development and to the demo. A
production release that mirrors a real site **refuses to start** with any of
them on: the mistake and the intention look identical from the outside, and the
difference is who can read the mirror. Running the bundled demo in a release is
still allowed without a flag (`CM_SOURCE=demo`); anything else needs
`MIRROR_ALLOW_UNSAFE_IDENTITY=1`.

`CM_PROXY_AUTH` is only safe when the app cannot be reached except through the
proxy.

## Webhooks

| Variable | Default | Purpose |
| --- | --- | --- |
| `CM_WEBHOOK_SECRET` | – | enables signed webhooks |
| `CM_WEBHOOK_REQUIRE_SIGNATURE` | `true` | reject deliveries without a valid signature |
| `CM_WEBHOOK_TOKENS` | – | `receiver=token,…` route-scoped webhook tokens |

## Search

| Variable | Default | Purpose |
| --- | --- | --- |
| `CM_SEARCH_PAGE_SIZE` | `30` | results per reader search page |
| `CM_SEARCH_DEFAULT_LIMIT` / `CM_SEARCH_MAX_RESULTS` | `25` / `100` | API/CQL default and cap |

## Mail and notifications

| Variable | Default | Purpose |
| --- | --- | --- |
| `MIRROR_NOTIFICATIONS` | `true` | enable e-mail notifications |
| `MIRROR_MAIL_FROM` / `MIRROR_MAIL_FROM_NAME` | `mirror@localhost` / `Confluence Mirror` | sender |
| `MIRROR_DIGEST_HOUR_UTC` | `8` | daily digest hour |
| `SMTP_RELAY` | – | enables SMTP delivery |
| `SMTP_PORT` | `587` (`2525` in dev) | SMTP port |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | – | SMTP credentials |
| `SMTP_TLS` | `always` | `never` disables TLS |
| `SMTP_AUTH` | `always` | `never` disables authentication |

## Storage

| Variable | Default | Purpose |
| --- | --- | --- |
| `MIRROR_BLOB_ROOT` | `var/mirror` | blob store root for attachment bytes |

## Reader rate limits

| Variable | Default | Purpose |
| --- | --- | --- |
| `CM_READER_RATE_LIMIT_PER_MINUTE` | – | enables reader limits (alias: `MIRROR_READER_RATE_LIMIT_PER_MINUTE`) |
| `CM_RATE_LIMIT_HTML_PER_MINUTE` | the base limit | HTML budget |
| `CM_RATE_LIMIT_API_PER_MINUTE` | half the base limit (min. 1) | JSON and Confluence-compatible API budget |
| `CM_RATE_LIMIT_ATTACHMENTS_PER_MINUTE` | twice the base limit | attachment budget |
| `CM_TRUST_PROXY_HEADERS` | `false` | limit readers by `X-Forwarded-For` instead of the socket address |

Anonymous readers are limited by address. Behind a reverse proxy or load
balancer that address is the proxy's, so every reader would share one budget and
one busy script would throttle the whole site — set `CM_TRUST_PROXY_HEADERS=true`
only when the mirror accepts traffic exclusively from that proxy. Signed-in
readers are always limited by identity, proxy or not.

A throttled browser request answers `429` with a page that names the retry
window (and a `Retry-After` header); API clients get JSON.

## Themes

Appearance is two decisions. The **theme** is the site's brand — one palette pair
for the whole mirror — and only an administrator chooses it, on
`/admin/settings`; the choice is stored in the `settings` table and seeded from
config. The **variant** is the reader's own from the header (`system`, `light`,
`dark`) and lives in a cookie. `default` and `fresh-blue` ship; a site adds its
own with `config :confluence_phx_mirror, :skins, [...]` (`name`, `label`, `note`,
`colors`, `dark_colors`, `radius`, `border`, `depth`, `noise`) or as a standalone
pack under `:skin_packs`. The full example, the supported colour keys and the
`assets/css/author.css` escape hatch are in
[site-admin-guide.md](site-admin-guide.md#themes-and-variants).

| Variable | Default | Purpose |
| --- | --- | --- |
| `CM_THEME` | `fresh-blue` | seeds the theme the whole site wears. An administrator changes it on **Admin → Settings**; readers only ever choose `system`, `light` or `dark`. A seeded name the site does not offer stops the release at boot |

## Development defaults

`config/dev.exs` starts with:

* `CM_SOURCE=demo` (no Confluence credentials needed),
* `MIRROR_AUTO_ADMIN` on, so no sign-in is required,
* `fresh-blue` as the theme, with the variant menu in the header,
* Postgres on `localhost:5432` and smtp4dev on `localhost:2525` — services that
  the repository's `docker compose` file happens to provide for local work.

`config/test.exs` uses Swoosh's test adapter and the blob root
`tmp/mirror_test`.
