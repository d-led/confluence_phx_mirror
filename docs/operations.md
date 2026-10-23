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
| Database pool | `POOL_SIZE` (default `20`), `POOL_COUNT` (default `1`), `POOL_TIMEOUT_MS` (default `15000`), `ECTO_IPV6` (`true` → `:inet6`) |
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

The release ships that command as an overlay too, so it is one word everywhere:
`bin/migrate` inside a container or a Machine. The image's own command only
starts the server (`/app/bin/server`); Fly runs `/app/bin/migrate` as its
`release_command`, Kubernetes as a Job, and a Compose or systemd deployment as a
one-off `ExecStartPre`. Do not let N instances race each other at boot — see
[deployment.md](deployment.md) for both platform configurations.

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

## Sizing the connection pool

The pool is DBConnection's (`Ecto.Adapters.Postgres` → Postgrex →
`DBConnection.ConnectionPool`). Four numbers decide it, and they interact:

| Setting | Env | Default | What it decides |
| --- | --- | --- | --- |
| `pool_size` | `POOL_SIZE` | 20 | connections in one pool |
| `pool_count` | `POOL_COUNT` | 1 | pools per replica, each with its own queue |
| `queue_target` / `queue_interval` | — | 200 ms / 2 s | when the pool starts pushing back |
| `timeout` | `POOL_TIMEOUT_MS` | 15 s | how long a request waits for a connection |

**The rule.** A replica opens `POOL_COUNT × POOL_SIZE` connections, so the whole
deployment is `replicas × POOL_COUNT × POOL_SIZE`, and that sum has to fit
Postgres' `max_connections` with room for migrations, Oban's own use of the same
pool and an operator's `psql`:

```
max_connections ≥ replicas × POOL_COUNT × POOL_SIZE + 10
```

Each replica states what it opened as it boots, so the multiplication above is
checked against reality rather than against the values you meant to set:

```
[info] database pool: 20 connections (1 × 20)
```

**Sizing from readers, not from hope.** A page view costs about 15 queries
(measured — `test/confluence_phx_mirror_web/query_budget_test.exs` pins the
number per screen). At ~2 ms per query, one connection serves roughly ten page
views per second, so:

| concurrent readers | busy page views/s | connections needed |
| --- | --- | --- |
| 200 | ~50 | 10–20 |
| 2 000 | ~500 | 60–100 |

Those are steady-state figures; a burst waits in the queue rather than failing,
which is what the queue knobs are for. The sync competes with readers for the
same pool, and it details pages `CM_SYNC_CONCURRENCY` at a time
(`attachments` + `comments` calls, each a few queries), so leave headroom for
`CM_SYNC_CONCURRENCY + 2` connections during a run.

**Why not "just make it huge".** Every connection is a Postgres process with its
own memory and its own share of `max_connections`; past a few hundred, context
switching costs more than the parallelism gains. Add replicas before you push
one pool past ~100, and check the numbers with the load tests rather than by
feel:

```bash
MIX_ENV=prod PHX_SERVER=true POOL_SIZE=40 CM_SYNC_CONCURRENCY=4 \
  PORT=4000 bin/confluence_phx_mirror start
scripts/load-test.sh 200 2000      # different host from the mirror, ideally
```

**Measured.** With only `POOL_SIZE` changed, throughput peaked near a hundred
connections per replica and fell by two thirds at a thousand: on a fixed number
of cores, extra backends only add context switches. Every size still missed the
800 ms p95 target, because the binding cost is the ~15 queries a page view
issues, not the number of connections. Past ~100 per replica, add replicas; the
current numbers are in [performance.md](performance.md).

**A huge pool has a second wall.** DBConnection opens every connection at once,
so the kernel's listen backlog decides how many get through: macOS clamps it to
128 (`kern.ipc.somaxconn`), and a pool in the thousands dies during boot with
`connection reset by peer`. Linux defaults to 4096 (`net.core.somaxconn`). Raise
the backlog before you raise the pool:

```bash
sudo sysctl -w kern.ipc.somaxconn=4096      # macOS needs root; Linux: net.core.somaxconn
```

**Reader sockets are a different resource, and they need no tuning here.** The
web server is Bandit, whose acceptor count and per-acceptor connection cap come
from Thousand Island: `num_acceptors` defaults to 100 and `max_connections` per
acceptor to 16 384, so 2000 sockets are two orders of magnitude below the
default (Cowboy's `transport_options: [num_acceptors: 100, max_connections:
10_000]` does not apply to Bandit). What does need attention is the file
descriptor limit of the process that starts the release:

```bash
ulimit -n 65536            # before starting the server; macOS defaults are low
```

**Measure a release, not a dev server.** `config/dev.exs` turns on
`debug_heex_annotations` (an attribute on every rendered element) and the code
reloader, which together cost most of the throughput: the same build served a
page at 259 rps in dev and 885 rps under `MIX_ENV=prod`, `/health` at 224
against 3 027. So dev numbers compare builds, not capacities — and a closed-loop
test with think time can never exceed `VUs / (think time + latency)`, which is
why the knee is found with a fixed arrival rate.

**Postgres itself.** The settings these runs were measured with are in
[`deploy/postgres-tuning.conf`](../deploy/postgres-tuning.conf) — `max_connections`,
`shared_buffers`, `effective_cache_size`, a deliberately small `work_mem`
(per sort node *per connection*), `random_page_cost` for SSD, and
`pg_stat_statements` so the next question is answered with numbers. Note that
`effective_io_concurrency` must be 0 on macOS: Postgres refuses to start on
platforms without `posix_fadvise()`.

**What a too-small pool looks like.** p95 climbing into seconds while CPU and
`pg_stat_activity` show short queries, plus `DBConnection.ConnectionError …
dropped from queue` in the logs. If `pg_stat_activity` shows long queries
instead, the fix is the query, not the pool.

**What a reader costs in RAM.** Two different shapes, and this application is
the cheap one. Reader pages — home, space, page, blog, search results, people —
are ordinary controller renders: no socket, no process per visitor, memory held
only while the response is assembled and released afterwards. The admin console,
the sync log and the advanced search panel are LiveViews, and every open page
holds a `PageChannel` process for the reader-count widget, so a browser tab does
keep a few tens of kilobytes on the server — but not the content.

A burst of 400 concurrent requests against one page moved the VM from 224 MB to
~320 MB RSS and back when it ended: about **190 KB per request in flight**,
transient. Sizing from it:

```
replica RAM ≈ baseline (200–250 MB) + peak concurrent requests × 0.2 MB + shared_buffers
```

Concurrent *readers* are not concurrent *requests*: a reader clicks every second
or two, and this application serves 400 simultaneous in-flight requests at
~870 rps, so 2000 readers at human pace do not produce 2000 requests in flight.
RAM was never the constraint in the load runs above — CPU and per-request work
were — and 2 GB of `shared_buffers` for a mirror whose whole corpus is a few
megabytes is already generous.

If you do grow the LiveView side (the sync log is the candidate), keep its
memory flat: streams for long lists (the log is a 400-entry ring, not an
assign), `temporary_assigns` for results that only need one render, and no
Ecto structs with loaded associations in a socket's assigns.

## Attached resources

* **Postgres** (`DATABASE_URL`) — content, links, search vectors, restrictions,
  accounts, the audit log and Oban jobs. The `sync` and `notifications` queues
  run inside the same release, and Oban coordinates them through Postgres, so
  running several instances is safe.

  Size the pool for the readers you expect — see
  [sizing the connection pool](#sizing-the-connection-pool); the total across
  the deployment is `replicas × POOL_SIZE`, and that is what `max_connections`
  has to accept.
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
  syncs; see the [admin reference](site-admin-guide.md#the-admin-area).
* Logs go to stdout through Elixir's console logger.

## Rate limiting

Three meters, in two directions:

* **Readers → mirror** — budgets per address for HTML, API and attachments,
  answering `429` with `Retry-After` and `X-RateLimit-*`. The knobs and the
  proxy rule are in [configuration.md](configuration.md#reader-rate-limits).
* **Confluence → mirror** — the webhook intake, always metered per client
  address (`CM_WEBHOOK_RATE_LIMIT_PER_MINUTE`, default 60), because a delivery
  is written and audited before its signature is checked. Unlike the reader
  budgets this one cannot be switched off; see
  [site-admin-guide.md](site-admin-guide.md#webhooks).
* **Client → Confluence**: the token bucket that protects your Confluence site
  is a sync setting; see
  [site-admin-guide.md](site-admin-guide.md#the-client-is-conservative-on-purpose).
* **Watching it work**: `/admin/sync-log` streams every call the sync makes —
  method, path, status, size and latency, with `waited=…` on the calls the
  bucket made queue and a `warn` line naming the wait before each retry. The run
  ends with a summary of the whole account: calls, bytes, average latency,
  retries, throttled time and failures, followed by the answers the site gave
  (`200×4200 429×31`). The same lines reach stdout at `debug` level, so a
  release can keep them in its log pipeline.

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
