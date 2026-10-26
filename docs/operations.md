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

### What makes a deploy migration safe

A deploy migration runs while the previous release is still serving — Fly rolls
Machines one at a time, Kubernetes one pod at a time — so for a while old code
reads the new schema. That leaves one rule: **a deploy migration may only add**,
in one of these forms.

| Change | Where it goes |
| --- | --- |
| new table, new nullable column, new column with a default | a deploy migration |
| new index | a deploy migration, built with `CREATE INDEX CONCURRENTLY` (below) |
| `NOT NULL`, rename, type change, column drop | expand → backfill → contract, over three deploys |
| backfilling rows | `priv/repo/manual_migrations`, in batches |

A plain `create index/3` holds a write lock for the length of the build — minutes
on `pages` once the mirror is large — and a `CONCURRENTLY` build cannot run
inside a transaction, so the transaction and the migration lock go with it:

```elixir
defmodule ConfluencePhxMirror.Repo.Migrations.IndexPagesCreatedAt do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS pages_created_at_index ON pages (created_at)",
      "DROP INDEX CONCURRENTLY IF EXISTS pages_created_at_index"
    )
  end
end
```

`test/confluence_phx_mirror/migrations_safety_test.exs` enforces both rules over
this directory: a plain index build outside a table-creating migration, a
`modify`/`remove`/`rename`, or SQL that rewrites rows fails the suite and names
the file. The migrations written before the rule are listed in that test as
legacy, each next to the shape it would take today. Fly's
[Safe Ecto Migrations](https://fly.io/phoenix-files/safe-ecto-migrations/) is the
long version of this section — the rename is its worked example of getting the
order wrong.

**One concurrent index build per table per migration.** Two
`CREATE INDEX CONCURRENTLY` statements on the same table deadlock against each
other — the first waits for the second's snapshot while the second waits for the
table's `ShareUpdateExclusiveLock` — and the migration is the side Postgres
aborts. If a table needs two indexes, write two migrations, or reconsider the
second index.

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
are ordinary controller renders, so the content is assembled while the response
is built and released afterwards. What outlives the request is small: a socket
and two LiveView processes per open tab — the footer's reader count, and on a
page the list of who is reading it — a few tens of kilobytes, never the
content. The admin console, the sync log and the advanced search panel are
LiveViews in their own right.

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
memory flat: streams for long lists (the sync log streams its rows — the
400-entry ring lives in `Sync.Log` and an open page holds none of it),
`temporary_assigns` for results that only need one render, and no Ecto structs
with loaded associations in a socket's assigns.

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

Two things must be backed up together, and restored together:

* **Postgres** — rows point at blob keys.
* **The blob root** — attachment bytes; restoring one without the other leaves
  broken attachments (or a mirror whose attachment links answer `404`).

`scripts/fly-pg-backup.sh` and `scripts/fly-pg-restore.sh` do this over
`fly proxy`, and they exist because two things are easy to get wrong:

* **The client must match the server's major version.** `pg_dump` refuses a
  newer server and no flag makes that safe, so the script asks the database
  machine which version it runs and looks for that `pg_dump` (PATH,
  `postgresql@N` from Homebrew, Debian's `/usr/lib/postgresql/N`).
* **The connection string is the app's own.** It is read out of the Machine
  that has `DATABASE_URL` rather than pasted into a shell, so nobody has to hold
  the database password to take a backup.

A restore is not finished when `pg_restore` exits: the blob volume has to be
restored to the same point (`fly volumes` snapshots, or your own copy of
`MIRROR_BLOB_ROOT`), and then a `/health` call — which counts pages, spaces and
attachments — should show the numbers you expect before the mirror is put back
behind the proxy.

Everything that is *not* in those two places is rebuildable: a snapshot
re-creates content, permissions and icons from the source, at the cost of the
requests it takes.

### A full re-read is a queue of spaces, not one run

"Re-read everything" on `/admin` queues **one sync per space** rather than a
single site-sized run. The reason is memory: a snapshot keeps every page's
source DTO and row alive from its first listing to its last detail call, which
on a hundred-thousand-page site is gigabytes — more than a 1 GB machine has, so
the node is killed rather than the run failing. The record it leaves is
`the process running this sync stopped before it finished`, and the next
schedule starts the same work from zero. Per space, the footprint is one
space's pages, a restart costs one space, and the sweep resumes where it stopped
by running again.

Two consequences worth knowing:

* **A sweep never trashes.** A snapshot trashes the spaces its listing no longer
  names; a sweep cannot tell a space that disappeared upstream from one it has
  not reached yet. Use `mix confluence.sync snapshot` (or the `:snapshot` mode)
  when spaces are deleted at the source.
* **Spaces are listed from the source, not from the mirror**, so a space the
  mirror has never seen is included — that is how a mirror whose snapshots kept
  dying finds the fifty spaces it never had.

A node that dies mid-job leaves its Oban row `executing`; `Oban.Plugins.Lifeline`
rescues those after thirty minutes and retries them, so the queue never keeps
listing work nobody is doing. `Oban.Pruner` keeps a finished job for a day
(`max_age: {1, :day}`) instead of the queue's default minute, because the job
row is the only per-space evidence a sweep leaves behind — "space LOAD431: 935
pages, done".

### A re-read, sized

The arithmetic behind the two settings in `fly.toml` (`CM_SYNC_CONCURRENCY`,
`POOL_TIMEOUT_MS`), measured on a 123,000-page site of 151 spaces:

* **Pace.** A full re-read wrote 14,621 pages in 86 minutes — about **2.8 pages
  per second**, network- and rate-limit-bound, on one shared vCPU.
* **A space** of ~935 pages therefore takes **5–6 minutes**; runs measured 3 to
  6. Two spaces is a coffee break, the whole site is **~12 hours** of continuous
  work (123,000 ÷ 2.8 ÷ 3600).
* **A sweep** is that work cut into 151 jobs, due **60 s apart**
  (`SweepWorker`). Spacing does not change the total; it keeps the queue a few
  rows deep instead of a hundred and fifty, and it means a restart costs the
  space in flight rather than the sweep.
* **Connections.** Each page in flight holds one database connection for its
  own transaction (page row, labels, properties, then text, links, comments).
  With `POOL_SIZE=10` and a four-page concurrency, a re-read put four writers on
  a one-vCPU database; transactions slowed, checkouts queued, and the pool's
  15 s patience ran out — `client … timed out because it queued and checked out
  the connection for longer than 15000ms` — which severs the connection and
  fails the whole run at the page it was writing. Hence **two pages at a time**
  and a **60 s** checkout: a slow write is waited for instead of killed.
* **What it costs.** Postgres is the bottleneck, not the app: the mirror's
  machine holds ~391 MB and the blob mount 1.5 MB, while the database has
  ~161 MB of data and one shared core to serve it. If a sweep still ends short,
  the next step is the database machine's size, not more app concurrency.

## Content the site no longer lists

A sync reconciles the spaces it lists: what the site stops returning is trashed
reversibly, mid-run. That leaves a question a sync cannot answer on its own —
*what do we hold that the site never mentions at all?* A space nobody has listed
since a deletion keeps its pages, and the mirror silently grows past the site.

`/admin/upstream` answers it. A **verify pass** asks, for every live space:

1. **a count per content type** — two requests, `limit=1`, reading the site's own
   `totalSize`. A space whose counts agree with the mirror's is finished here and
   no page is listed at all, which is every space on a healthy mirror;
2. **an id-only listing** for a space whose counts disagree (or for a source that
   cannot count): the same pagination as a sync, with no bodies, comments,
   attachments or expansion;
3. nothing else. No page is read, rendered or re-synced.

The site's answer is **recorded, not acted on**: pages it did not name get
`absent_since` and stay readable, because a listing that leaves a page out can
also be a permission the token lost. An operator reviews the list and trashes
what should go — one page or a whole space — which is the same reversible trash
a sync uses.

Two numbers to size it by: a 150-space site costs ~300 count requests when
nothing is wrong (~1 minute at the polite 5/second pace), and only the spaces
that disagree pay a listing.

A pass over a large site outlives a deploy, so it is **resumable**: every space it
settles is written down (`reconcile_observations`) as it is settled, and an
unfinished pass is *continued* rather than restarted — the next attempt asks only
about the spaces the last one did not reach, and its report still covers the whole
pass. Only one pass is ever in flight (the worker's uniqueness is keyed on the
worker, not on the arguments, so two operators cannot start two). A pass left
unfinished for more than a day is abandoned instead: its first spaces would be a
day old, and a stale answer is worse than a new question. The screen shows a pass
in flight, with how many spaces it has settled, rather than saying nobody has
checked.

### Content that comes back

A page the site names again is live again. Two things make that true:

- a verify pass clears `absent_since` for every page its listing names;
- a sync that *reads* a page clears the absence and lifts a trash it caused
  itself. Confluence does not bump a page's version when it restores it from its
  own trash, so the version test alone would leave the page dead for good: the
  sync therefore also writes any page the mirror holds as absent or as vanished.

A page an operator trashed by hand (`deleted_reason: "manual"`) is the exception.
That was a decision, not an inference, and a sync does not undo it — the page
waits in the trash until somebody purges it.

### Deleting the trash later

The trash is a holding area, not a bin. `/admin/trash` has a **Delete it later**
control: it says how many spaces and pages have been there longer than the
holding period you type (30 days to begin with) and removes exactly those — rows,
comments and attachment blobs, one audit entry per row. Nothing live is ever
included, however old its absence.

Both bulk actions run as Oban jobs on the `:sync` queue, not inside the click:
`ConfluencePhxMirror.Sync.TrashAbsentWorker` takes a space's absent pages and
`ConfluencePhxMirror.Trash.PurgeWorker` takes the expired rows, so a mirror with
thousands of either never builds the work into a request. `/admin/jobs` shows
each with its scope, and the audit trail names whose decision it was. The same
two steps are available in code:

```elixir
ConfluencePhxMirror.Trash.due(30)              # what a policy would remove
ConfluencePhxMirror.Trash.purge_due(actor, 30) # remove it
```

`pages.deleted_reason` records why a row is there: `"vanished"` when the site
stopped listing it, `"manual"` when somebody decided.

## Watching it

* `/health` — database check, content counters, last sync. No auth, so it can
  back a probe.
* `/admin` — freshness, sync runs, audit log, webhook deliveries, manual
  syncs; see the [admin reference](site-admin-guide.md#the-admin-area).
* `/admin/runtime` — Phoenix LiveDashboard: the BEAM's own numbers, plus the
  mirror's (`confluence_mirror` in its metric list). Off by default; see below.
* Logs go to stdout through Elixir's console logger.

### The runtime dashboard, if you want it in production

LiveDashboard shows what a BEAM node is doing — processes, ETS contents, ports,
sockets, memory — and lets you kill a process or restart an application. That is
exactly what you want while debugging a busy mirror, and nothing a reader should
be able to reach, so the route is compiled in only where a deployment asks for
it and then sits behind the administrator role:

    # config/prod.exs
    config :confluence_phx_mirror, admin_dashboard: true

Decision recorded at build time (`Application.compile_env/2`), so turning it on
is a rebuild, not a restart; the role check itself is per request, through
`LiveUserAuth.on_mount(:admin)`, so demoting an administrator closes the screen
without a deploy. Two things to weigh before enabling it on a public host:

* **It is another admin surface.** Anyone who can sign in as an administrator
  sees session tables, cached bodies and absolute paths. Keep the proxy in front
  of it, and keep the administrator list small.
* **It can stop the mirror.** Killing a process from it is a click, and it does
  not ask again.

If all you need is the numbers, leave it off: the same metrics are collected by
`ConfluencePhxMirrorWeb.Telemetry` and can be scraped or reported without the
dashboard — `catalogue_metrics: true` makes the poller publish how many pages,
spaces and attachments the mirror holds, and every rendered page publishes a
`confluence_mirror.page.view` event.

Its **OS Data** page (CPU load, memory, every mount, with history) appears
because the release starts `os_mon`; without that application the page does not
exist. Two differences from the overview's own Resources strip are worth
knowing before reading either: LiveDashboard counts memory *free* where the
overview counts *available* — on a healthy Linux box those are 99% and 83% of
the same machine — and it lists every mount, where the overview names the one
the blob root is on. The route is served with its own content policy
(`Plugs.DashboardCSP`), because LiveDashboard injects one inline script its
bundle depends on and the reader pages forbid inline script; that exception is
one route wide and exists only when the dashboard is compiled in.

Its **Metrics** page charts the catalogue under the `confluence_mirror` nav —
pages, spaces, attachments, comments, labels, what sits in the trash, accounts,
blob bytes and database bytes — one point per poll (10 s) plus the same numbers
the run that just finished wrote. The last two hours are kept in memory
(`ConfluencePhxMirror.MetricsHistory`, 720 points per series); nothing is
persisted, so a restart starts the charts over. Read a value by putting the
cursor over the plot: the legend shows `--` while the cursor is elsewhere,
which is uPlot's idle state, not an empty chart.

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

`/admin` answers the two sizing questions an operator asks when a sync dies or
a disk fills: **Resources** shows what `MIRROR_BLOB_ROOT` holds (every file
under it, counted once a minute by `ConfluencePhxMirror.Resources`), the room
left on the device that path is on (`df`, in total and in percent, amber from
75% and red from 90%), the size of the running database with its biggest
tables, and the machine's memory — total minus *available*, so a page cache is
not read as an emergency — with the part this VM holds underneath it, which is
the half of the answer a large sync grows. On Fly the blob root is its own
volume (`mirror_blobs`, 1 GB by default), so that is the number that decides
whether a sync can keep going; Postgres lives on another machine, so its figure
carries no percentage. Memory comes from `os_mon` (`memsup`), which the release
starts with the application.

Postgres can say what it **uses** and never what is **left**: `pg_database_size`,
`pg_tablespace_size` and `pg_total_relation_size` are all it has, and there is no
SQL function over `statvfs`. The database card therefore shows the database, its
on-disk footprint including WAL, and its biggest tables; set
`CM_DATABASE_CAPACITY_GB` to the size of its volume (on Fly: `fly volumes list`)
and it also draws a percentage, the same way the blob mount does.

Each bar is a composition rather than a gauge: the blue slice is what this
deployment put there, the grey is everything else on the same device, and the
track is what is left — a mirror holding two megabytes of a disk a build cache
filled should not read as the culprit. Shares are drawn to a tenth of a percent,
because "0%" and "a sliver" are different answers and the dev box is the second
one. The alarm lives on a ring around the bar rather than in its fill (amber from
75%, red from 90%): a tinted free space reads as filled, which turns a full disk
into a confusing one. A device that did not report its size gets no share at all.

An open overview is read at two speeds: the run in flight every five seconds,
because that is what an operator sits and watches, and everything else — the
totals, the run table, the audit tail, the resource figures — on
`CM_ADMIN_STATS_REFRESH_SECONDS` (30 by default), because a mirror's totals do
not move between heartbeats. A finished run refreshes the slow half at once, so
the table never says "running" after the strip is gone.

## Notifications

Delivery state is an outbox row per notification with its own status; Oban
retries failed sends. `MIRROR_NOTIFICATIONS=false` turns notification creation
off, `MIRROR_DIGEST_HOUR_UTC` moves the daily roll-up, `MIRROR_MAIL_FROM` and
`MIRROR_MAIL_FROM_NAME` set the sender.
