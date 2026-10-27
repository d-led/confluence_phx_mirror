# Configuration

Everything the mirror reads from the environment, plus the one compile-free
customisation point (themes). The app is configured only through the environment
(12-factor).

This file is the exhaustive list, so keep it honest: if a variable is read in
`config/` or `lib/`, it belongs here.

## Two kinds of setting

| Kind | Where you change it | Applies |
| --- | --- | --- |
| **Live** — read per request or per job | `/admin/settings`, or the variable | at once |
| **Boot** — everything else | the variable, then restart | on the next boot |

Booleans accept `1`, `true` or `yes`. A running development server does **not**
reload `config/*.exs` changes.

Sections: [live settings](#live-settings) ·
[platform](#platform) ·
[source and sync](#source-and-sync) ·
[accounts and sign-in](#accounts-and-sign-in) ·
[webhooks](#webhooks) · [search](#search) ·
[API description](#api-description) · [exports](#exports) ·
[mail](#mail-and-notifications) · [storage](#storage) ·
[reader rate limits](#reader-rate-limits) · [themes](#themes) ·
[development defaults](#development-defaults)

## Live settings

These are read *while* the mirror serves a request or runs a job. An
administrator changes them on `/admin/settings` and the change takes effect at
once. The variable seeds the value a mirror nobody has touched uses, and *use
the deployment's values* hands a group back to it.

The declared list is `ConfluencePhxMirror.Settings.Catalogue`; a save writes the
`settings` table, audited as `settings.updated`. Adding a setting needs **no
migration** — `settings` is a key/value table, so a key it has never seen is
simply absent, and one the code no longer knows is ignored on load. Upgrading
and rolling back never touch stored decisions.

**Reading and appearance**

| Setting | Variable | Default |
| --- | --- | --- |
| `theme` | `CM_THEME` | `fresh-blue` |
| `reader.html_limit` | `CM_READER_RATE_LIMIT_PER_MINUTE` / `CM_RATE_LIMIT_HTML_PER_MINUTE` | `240` |
| `reader.api_limit` | `CM_RATE_LIMIT_API_PER_MINUTE` | `120` |
| `reader.attachments_limit` | `CM_RATE_LIMIT_ATTACHMENTS_PER_MINUTE` | `300` |
| `search.page_size` | `CM_SEARCH_PAGE_SIZE` | `30` |
| `search.default_limit` | `CM_SEARCH_DEFAULT_LIMIT` | `25` |
| `search.max_results` | `CM_SEARCH_MAX_RESULTS` | `100` |

**Sync**

| Setting | Variable | Default |
| --- | --- | --- |
| `sync.spaces` | `CM_SPACES` | none added |
| `sync.interval_seconds` | `CM_SYNC_INTERVAL_SECONDS` | `3600` |
| `sync.reconcile_interval_seconds` | `CM_RECONCILE_INTERVAL_SECONDS` | `0` |
| `sync.paused` | `CM_SYNC_PAUSED` | `false` |
| `sync.concurrency` | `CM_SYNC_CONCURRENCY` | `4` |
| `sync.detail_backlog` | `CM_SYNC_DETAIL_BACKLOG` | `200` |
| `sync.lookback_seconds` | `CM_SYNC_LOOKBACK_SECONDS` | `3600` |
| `confluence.page_size` | `CM_HTTP_PAGE_SIZE` | `50` |

**Notifications, webhooks, accounts**

| Setting | Variable | Default |
| --- | --- | --- |
| `notifications.enabled` | `MIRROR_NOTIFICATIONS` | `true` |
| `notifications.digest_hour_utc` | `MIRROR_DIGEST_HOUR_UTC` | `8` |
| `webhook.enabled` | `CM_WEBHOOK_ENABLED` | `true` |
| `webhook.require_signature` | `CM_WEBHOOK_REQUIRE_SIGNATURE` | `false` |
| `webhook.rate_limit` | `CM_WEBHOOK_RATE_LIMIT_PER_MINUTE` | `60` |
| `accounts.login_token_minutes` | `CM_LOGIN_TOKEN_MINUTES` | `15` |
| `export.personal_spaces` | `CM_EXPORT_PERSONAL_SPACES` | `false` |
| `dashboard.refresh_seconds` | `CM_ADMIN_STATS_REFRESH_SECONDS` | `30` |

The webhook switches are edited on `/admin/webhooks`, where the cost of each is
spelled out; everything else is on `/admin/settings`.

**Not live, however it looks:** `CM_REQUESTS_PER_SECOND` and `CM_BURST` are
options of the rate limiter's process, so they are read at boot. The source, the
credentials, the database, the blob root, secrets and the sign-in switches are
boot settings too; `/admin/settings` lists them with the variable that sets each.

A save is one transaction: every field of the change and its audit entry commit
together or not at all, so a save that reports an error changed nothing.

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
| `CM_SPACES` | all | comma-separated space keys: naming any makes them the whitelist, and a snapshot then trashes every mirrored space the listing does not contain (see [pulling content](site-admin-guide.md#pulling-content)). `sync.spaces` adds to this list at runtime |
| `CM_REQUESTS_PER_SECOND` / `CM_BURST` | `5` / `5` | client rate limit (token bucket) |
| `CM_HTTP_RETRIES` | `3` | attempts per Confluence request |
| `CM_HTTP_PAGE_SIZE` | `50` | content page size when paginating; `confluence.page_size` changes it at runtime |
| `CM_HTTP_RETRY_BACKOFF_MS` | `250` | first retry delay (doubles per attempt) |
| `CM_SYNC_PAUSED` | `false` | stop reading from the site entirely: runs are refused, queued jobs wait, and every screen says the mirror is paused. The button beside *Sync now* on `/admin` flips it at runtime (`sync.paused`) |
| `CM_SYNC_INTERVAL_SECONDS` | `3600` | gap between scheduled pulls; `0` switches the timer off. `sync.interval_seconds` changes it at runtime, and a new cadence applies from the tick after the one in flight |
| `CM_RECONCILE_INTERVAL_SECONDS` | `0` | scheduled missing-pages check — a verify pass over every space (`0` keeps it on demand, from `/admin/upstream`). `sync.reconcile_interval_seconds` changes it at runtime, and `0` is a number the screen accepts: that is how the pass is switched off |
| `CM_SYNC_LOOKBACK_SECONDS` | `3600` | minimum window for an incremental pull |
| `CM_SYNC_CONCURRENCY` | `4` | changed pages detailed at once |
| `CM_SYNC_PERSONAL_SPACES` | `false` | mirror personal (`~account`) spaces — every user has one, and it holds their drafts. A mirrored one is still readable only by its owner and by administrators |

Scheduled pulls are incremental: they ask Confluence only for content that
changed since the last run, and pages whose version is unchanged are skipped
without being re-rendered or asked for their attachments and comments. A full
re-read is available on demand — "Re-read everything" under the sync-run table
on the dashboard, which says what it costs and asks before it queues, or
`mix confluence.sync --mode snapshot`; expect it to cost one request per page
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
| `CM_PROXY_AUTH_MEMBERS_ONLY` | `true` | admit only administrators and identities the sync has seen on the mirrored site (the default rule when no policy is named) |
| `CM_PROXY_AUTH_GROUPS_HEADER` | – | header carrying group names the identity provider asserts, e.g. `x-forwarded-groups` (CSV) |
| `CM_USER_POLICY` | – | who may have an account: `new_users_can_read_public_spaces` (alias `allow_all`) or `readers_must_exist_in_confluence` (alias `members_only`) |
| `MIRROR_ALLOW_SITE_DISABLED_READERS` | `false` | let readers Confluence reports as *inactive* read anyway; accounts the site no longer has, and banned accounts, stay out |
| `MIRROR_ALLOW_UNSAFE_IDENTITY` | `false` | acknowledge the three switches above in a production release |

`MIRROR_AUTO_ADMIN`, `MIRROR_SELF_SIGNUP` and `CM_PROXY_AUTH` each hand out an
identity without a sign-in, so they belong to development and to the demo. A
production release that mirrors a real site **refuses to start** with any of
them on: the mistake and the intention look identical from the outside, and the
difference is who can read the mirror — and, because an administrator can empty
the trash, who can delete its content for good. Running the bundled demo in a
release is still allowed without a flag (`CM_SOURCE=demo`); anything else needs
`MIRROR_ALLOW_UNSAFE_IDENTITY=1`.

`CM_PROXY_AUTH` is only safe when the app cannot be reached except through the
proxy.

Who may have an account is a policy, not a switch:
`ConfluencePhxMirror.Accounts.UserPolicy` answers one question — may this arriving
identity become a reader — and knows nothing about what a reader may open. Two
ship: `new_users_can_read_public_spaces` (alias `allow_all`) and
`readers_must_exist_in_confluence` (alias `members_only`, the default).

Which policy applies at which door, how they compose, and what replaces them when
none is named: [routes-auth.md](routes-auth.md#admission-may-this-identity-have-an-account).

## Webhooks

| Variable | Default | Purpose |
| --- | --- | --- |
| `CM_WEBHOOK_ENABLED` | `true` | `false` switches the intake off: every delivery is answered exactly like a path that is not routed (the endpoint's own 404) and nothing is stored, not even the attempt. The reply does not say a webhook endpoint exists |
| `CM_WEBHOOK_SECRET` | – | the secret Confluence signs with; without it no signature can be checked |
| `CM_WEBHOOK_REQUIRE_SIGNATURE` | `false` | `true` refuses deliveries that present no valid signature or token (and answers `503` when no secret is configured). An administrator can override this on `/admin/webhooks` at runtime |
| `CM_WEBHOOK_TOKENS` | – | `receiver=token,…` route-scoped webhook tokens |
| `CM_WEBHOOK_RATE_LIMIT_PER_MINUTE` | `60` | per-client cap on the intake, always on (see [operations.md](operations.md#rate-limiting)); an administrator can override it at runtime |

Unsigned deliveries are accepted by default, and `/admin/webhooks` says so in a
banner until an administrator requires signatures — there or through the
variable. A delivery is stored and audited before its signature is verified, so
the route is metered whatever the reader limits say. Who may call it, and what a
delivery does, are in the [site admin guide](site-admin-guide.md#webhooks).

## Search

| Variable | Default | Purpose |
| --- | --- | --- |
| `CM_SEARCH_PAGE_SIZE` | `30` | results per reader search page |
| `CM_SEARCH_DEFAULT_LIMIT` / `CM_SEARCH_MAX_RESULTS` | `25` / `100` | API/CQL default and cap |

## API description

| Variable | Default | Purpose |
| --- | --- | --- |
| `CM_API_DOCS` | on in dev/test, off in a release | serve `/api/docs` (the page) and `/api/openapi.json` (OpenAPI 3.1); when off both answer `404` |

## Exports

| Variable | Default | Purpose |
| --- | --- | --- |
| `CM_EXPORT_PERSONAL_SPACES` | `false` | include personal spaces in the whole-site static archive (`/admin/export/site.zip`). Off by default: a site archive is a file that leaves the building, and somebody's own space — drafts, notes, half-finished pages — is not part of "the site". One space's own archive is unaffected either way |

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

`CM_THEME` seeds the palette pair the whole site wears. Readers choose only
`system`, `light` or `dark` — their own cookie. Choosing, declaring and shipping
a theme, with the config keys a site may set, is
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
