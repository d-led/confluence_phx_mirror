# Operating a mirror

This is the deployment and operations guide: how the mirror is built, configured
and run. It is for whoever owns the servers. Running the mirror *as a product* —
syncs, accounts, permissions, webhooks — is
[site-admin-guide.md](site-admin-guide.md).

The mirror is a **12-factor** app: one OTP release, configuration only from the
environment, Postgres and SMTP as attached resources, and no state on local disk
except the blob root you give it.

## One artifact, built once

```bash
MIX_ENV=prod ./scripts/mix_release.sh     # deps, assets, digests, `mix release`
bin/confluence_phx_mirror start
```

`scripts/mix_release.sh` fetches production deps, compiles, digests and builds
the assets, then produces the release. The `Dockerfile` in this repository is one
example of that build — nothing in the application assumes Docker, Compose or a
particular platform. Any process manager that can run the release binary with the
environment below is a supported deployment.

## The environment is the contract

| What | Variables |
| --- | --- |
| Required | `DATABASE_URL`, `SECRET_KEY_BASE` |
| Web server | `PHX_SERVER=true` (the release serves HTTP only when set), `PORT` (default `4000`), `PHX_HOST` (absolute URLs and secure cookies) |
| Database pool | `POOL_SIZE` (default `10`), `ECTO_IPV6` (`true` → `:inet6`) |
| Clustering | `DNS_CLUSTER_QUERY` |
| Confluence sync | `CM_*` — see [configuration.md](configuration.md) |
| Mail | `SMTP_RELAY`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_TLS`, `SMTP_AUTH` |

Everything else has a working default, including `CM_SOURCE`: with neither
`CM_SOURCE` nor `CM_CONFLUENCE_SITE` set the mirror serves the demo snapshot.
There is no environment-specific config file to edit and no secret baked into
the release.

Production enables `force_ssl` (rewriting on `X-Forwarded-Proto`, localhost
excluded), so terminate TLS at your ingress or forward the scheme to the app.

## Migrate as a deploy step

Run migrations **once per deploy**, before new instances take traffic:

```bash
bin/confluence_phx_mirror eval "ConfluencePhxMirror.Release.migrate"
```

The example Dockerfile does exactly that in its command
(`eval Release.migrate && exec ... start`); a release job, a `Procfile` release
phase or a systemd `ExecStartPre` does the same. Do not let N instances race each
other at boot.

Migrations are split by *when* they may run:

| Directory | Applied | Use for |
| --- | --- | --- |
| `priv/repo/migrations` | on every deploy — the release calls `Release.migrate/0` | additive schema changes that old and new code both tolerate |
| `priv/repo/manual_migrations` | only when an operator asks | slow indexes, destructive changes, data backfills |

```bash
mix ecto.gen.migration --migrations-path=priv/repo/manual_migrations backfill_status
bin/confluence_phx_mirror eval "ConfluencePhxMirror.Release.migrate_manual"
```

Development and test apply both directories (`mix ecto.migrate_all`), which is
what `mix setup` and the `test` alias use.

## Attached resources

* **Postgres** (`DATABASE_URL`) — content, links, search vectors, restrictions,
  accounts, the audit log and Oban jobs. The `sync` and `notifications` queues
  run inside the same release, and Oban coordinates them through Postgres, so
  running several instances is safe.
* **SMTP** — `SMTP_RELAY` plus credentials; sends are retried per notification,
  so a mailer outage never blocks a sync.
* **Blob root** (`MIRROR_BLOB_ROOT`, default `var/mirror`) — attachment bytes.
  `Blobs.LocalStore` is a filesystem path: with more than one instance that path
  must be shared storage, or `Blobs.Store` needs an object-storage
  implementation.

## State and backups

Two things must be backed up together:

* **Postgres** — rows point at blob keys.
* **The blob root** — attachment bytes; restoring one without the other leaves
  broken attachments.

## Watching it

* `/health` — database check, content counters, last sync. No auth, so it can
  back a probe.
* `/admin` — freshness, sync runs, audit log, webhook deliveries, manual
  syncs; see the [admin reference](site-admin-guide.md#the-admin-dashboard).
* Logs go to stdout through Elixir's console logger.

## Rate limiting

* **Reader → mirror**: `CM_READER_RATE_LIMIT_PER_MINUTE` (HTML, API and
  attachments get separate budgets, overridable with
  `CM_RATE_LIMIT_HTML_PER_MINUTE`, `CM_RATE_LIMIT_API_PER_MINUTE`,
  `CM_RATE_LIMIT_ATTACHMENTS_PER_MINUTE`). Responses carry `X-RateLimit-Limit`
  and `X-RateLimit-Remaining`; rejections are `429` with `Retry-After`.
* **Client → Confluence**: the token bucket that protects your Confluence site
  is a sync setting; see
  [site-admin-guide.md](site-admin-guide.md#the-client-is-conservative-on-purpose).

## Attachments on disk

```
var/mirror/spaces/ENG/pages/1002/attachments/9001/diagram.svg
```

* Keys: space → page → attachment id → sanitised filename (traversal-proof).
* Writes are atomic (temp file + rename).
* Served by `AttachmentController` with media type, ETag and
  `Content-Disposition`; inline for images/PDF/text, download otherwise.
* Never in Postgres and never under `priv/static`.
* `Blobs.Store` is a behaviour, so an S3 implementation is a drop-in.

## Notifications

Delivery state is an outbox row per notification with its own status; Oban
retries failed sends. `MIRROR_NOTIFICATIONS=false` turns notification creation
off, `MIRROR_DIGEST_HOUR_UTC` moves the daily roll-up, `MIRROR_MAIL_FROM` and
`MIRROR_MAIL_FROM_NAME` set the sender.
