# Performance testing

Two questions, two harnesses. The reader screens must stay **bounded** — a page
view must cost a fixed number of statements and a fixed number of bytes, however
large the mirror is — and the server as a whole must hold up under **concurrent
readers**. The first question is answered by a test suite you can run in CI; the
second by a load generator pointed at a running mirror.

Neither is a benchmark you "just run": a laptop under load, a shared Postgres and
a development server with a code reloader all change the numbers. What follows is
what to set up, how to run it, and how to read what comes out.

* budgets in the suite: `test/confluence_phx_mirror_web/scale_test.exs`
* load against a server: `scripts/load-test.sh`, `k6-load-tests/reader.js`, `hey`
* sample data: `ConfluencePhxMirror.Confluence.SyntheticContent` and
  `ConfluencePhxMirror.Confluence.SyntheticSource`

## Where the data comes from

Both harnesses need a mirror that is big enough to show the shape of a read.
Nothing in the repository ships one: `CM_SOURCE=demo` is a dozen pages, and a
page view that quietly loads a whole space looks exactly like a fast one at that
size.

`ConfluencePhxMirror.Confluence.SyntheticContent` generates content from an
index: spaces, a page tree of `branching` children per page, prose, bylines,
labels, versions and timestamps. The same documents feed two writers:

| writer | built for | how the rows arrive | cost |
| --- | --- | --- | --- |
| `ConfluencePhxMirror.Confluence.SyntheticSource` | a running server, and any test of the sync itself | `Sync`, exactly like a Confluence site: one page at a time, rendered and indexed | ~4 ms per page: 30 000 pages took 12 minutes on a loaded laptop |
| `ConfluencePhxMirror.Synthetic` (test support) | the scale suite | `insert_all` batches of the rows a snapshot would have written, local ids assigned up front so the tree resolves at insert time | ~6 min for 1 000 000 pages |

The fast writer is not a second implementation of ingestion: it maps documents
through `Sync.page_attrs/1` and `Sync.search_text/4` — the functions the real
pipeline uses — and
`test/confluence_phx_mirror/confluence/synthetic_source_test.exs` asserts that a
sync of a small generated site and the fast fixture produce the same rows,
including the searchable text. If you change the generator, that test is what
keeps a benchmark honest.

The prose is generated but *readable*, and different pages say different things
(rotated subjects, tools, metrics, risks), so full-text search ranks and
snippets a fixture the way it would rank a real wiki. A fixture whose pages were
only findable by title would make search look like it works when it does not.

### From a real Confluence site

Generated content exercises the mirror; it cannot exercise `HttpSource`. To
measure pagination, retry and rate-limiting against a real Cloud instance, a
free site is enough — [rewind-community's test data
generator](https://github.com/rewind-community/confluence-test-data-generator)
writes spaces and pages through the REST API, and `--content-only` keeps it to
text, which is the part the free plan does not meter (2 GB counts attachments).

```bash
# --count is pages + blog posts, not pages: at the default multipliers a page is
# ~16% of it. 20 spaces of ~95 pages each, no attachments, clearable prefix.
CONFLUENCE_API_TOKEN=... python confluence_data_generator.py \
  --url https://acme.atlassian.net/wiki --email you@acme.com \
  --count 12523 --spaces 20 --content-only --prefix PERFSP --dry-run

# Same command without --dry-run writes it; --cleanup --prefix PERFSP --yes
# deletes every space whose key starts with the prefix (permanently).
```

What that cost, measured on a free site: **668 pages in ten minutes**
(concurrency 5, ~1.1 pages/s) before the generator died with an empty
`TimeoutError`; it checkpoints only after a whole phase, so `--resume` redoes the
page phase. Treat it as an unattended job with a small `--count` and a prefix you
can clean up: ~100 000 pages is a day of API budget, not an hour.

Mirroring what it created is the second measurement, and the more useful one:

```bash
CM_SOURCE=http CM_CONFLUENCE_SITE=https://acme.atlassian.net \
  CM_ATL_EMAIL=you@acme.com CM_ATL_TOKEN=... CM_REQUESTS_PER_SECOND=10 \
  mix confluence.sync --mode snapshot      # 732 pages, 21 spaces, 253 s
```

732 pages in 253 s is **2.9 pages/s** at `CM_REQUESTS_PER_SECOND=10`: the sync is
bound by the request budget, not by Postgres, so plan a first snapshot of 100 000
pages at ~10 hours (and watch for 429s before raising the budget).

Two things that surprise a reader on real data: page URLs carry a slug, so
`/spaces/KEY/pages/ID` answers 302 to the canonical URL — point a load generator
at `_links.webui` from the REST listing, which is what `reader.js` does; and the
generator writes lorem ipsum, so a search for a word from *your* site measures the
old pages only. Search for a word from the generated bodies instead.

## Starting a server on specific test data

Generated content is a fixture, so it gets its own database
(`confluence_phx_mirror_dev_synthetic`) and its own `CM_SOURCE`. A real mirror's
database is never touched, and nothing here can be mistaken for mirrored
content.

```bash
# 1. Build a mirror of 100 spaces × 300 pages (30 000 pages, about ten minutes).
CM_SOURCE=synthetic mix ecto.drop
CM_SOURCE=synthetic mix ecto.create
CM_SOURCE=synthetic mix ecto.migrate_all
CM_SOURCE=synthetic CM_SYNTHETIC_SPACES=100 CM_SYNTHETIC_PAGES=300 \
  CM_SYNTHETIC_BRANCHING=10 mix confluence.sync --mode snapshot

# 2. Serve it. Two settings decide whether you measure the mirror or a guard rail:
#    the reader rate limit would turn a load test into 429s, and a scheduled pull
#    would compete with the readers.
CM_SOURCE=synthetic CM_READER_RATE_LIMIT_PER_MINUTE=600000 CM_SYNC_INTERVAL_SECONDS=0 \
  POOL_SIZE=20 mix phx.server
```

The sizes come from `CM_SYNTHETIC_SPACES`, `CM_SYNTHETIC_PAGES` and
`CM_SYNTHETIC_BRANCHING`; every variable is listed in
[configuration.md](configuration.md#source-and-sync). `mix ecto.setup` instead
of the three migration steps also works — it seeds from the configured source.

Two traps worth knowing:

* **A re-sync does not re-render.** The generated version of a page depends only
  on its index, so after changing the generator a snapshot sync finds every page
  unchanged and keeps the old bodies. Drop the database and sync again.
* **Drop with no server running.** Postgres refuses to drop a database other
  sessions are attached to. Stop `mix phx.server` first (`pkill -f "phx[.]server"`),
  or `pg_terminate_backend/1` the sessions.

`GET /api/v1/stats` is the quick check that the data you expect is loaded
(`pages`, `spaces`, `attachments`) before a single number is measured.

## Part 1 — reader budgets in the suite

```bash
mix setup                                            # once: databases and demo content
MIX_TEST_PARTITION=scale mix test --only scale       # 1000 spaces × 1000 pages

# While working, a cheaper size:
CM_SCALE_SPACES=20 CM_SCALE_PAGES=1000 MIX_TEST_PARTITION=scale mix test --only scale

# One case, plus cprof (call counts) and eprof (time per function) of a page view:
CM_PROFILE=1 MIX_TEST_PARTITION=scale mix test --only scale \
  test/confluence_phx_mirror_web/scale_test.exs
```

The suite is tagged `:scale` and excluded from `mix test`; `MIX_TEST_PARTITION=scale`
gives it its own database (`confluence_phx_mirror_testscale`) so it cannot
collide with another run. Everything is written inside one sandbox transaction
and rolled back, so a run leaves no rows behind.

### What it prints

```
  a deep page
    3.85 ms median, 5.35 ms worst, 48.1 KB
    16 queries, 3.24 ms in SQL
      1× 0.51 ms  SELECT p0."id", p0."space_id", p0."parent_id", ...
      1× 0.23 ms  SELECT p0."id", p0."confluence_id", ...
      ...
```

Read it against the question each line answers:

| line | question |
| --- | --- |
| `N queries` | is the read bounded? This is the number a regression breaks — it is exact, and it does not move with the size of the mirror |
| `… ms in SQL` | how much of the request is the database? If this is most of the total, the fix is a query or an index |
| statement list | one line per distinct statement, with its count. `3×` of the same statement is an N+1; a statement the screen has no business running is a missing `preload` or an unneeded one |
| median / worst | what a reader feels. Reported, never asserted |
| KB | the size of the response. A screen that carries the whole space shows up here before it shows up in the timings |

`test/confluence_phx_mirror_web/query_budget_test.exs` does the same thing over
the demo snapshot on every `mix test`: same measure, small data, so a change that
adds a query per row fails immediately rather than at scale.

### How to read a regression

1. **Statements grew** → compare the statement list with the last one. A
   repeated statement is an N+1 (a `preload` that disappeared, a predicate asked
   per row); a new statement is an extra lookup a screen did not need.
2. **Bytes grew** → something is listing more than a window: a whole space, every
   space, every tag. The fix is a bounded list plus a link to the catalog that
   pages in the database.
3. **SQL time grew, statements did not** → look at the statement itself with
   `EXPLAIN (ANALYZE)` on the same data. At scale the usual answer is a missing
   index (see `pages.updated_at`, added for `Mirror.Counters`) or an aggregate
   over the whole table that belongs in `Mirror.Counters`, which computes
   content-derived totals once per version instead of once per request.

Budgets are ceilings that only go down: when a change makes a screen cheaper,
lower the number in the test in the same commit.

### Profiling with eprof and cprof

`CM_PROFILE=1` runs `:cprof` (how often each function is called) and `:eprof`
(how much time it spends) over one page view. Use `cprof` when you suspect a
function is called far more than the work needs, `eprof` when the milliseconds
are somewhere unexpected. Both are in Erlang's `:tools` — no dependency, and they
work on a release node through a remote shell.

## Part 2 — load against a running server

With a server up on generated data (`POOL_SIZE` and the rate limit raised, no
scheduled pull), the two generators to reach for are `k6` for a reader journey
and `hey` for one endpoint at a time.

```bash
# A reader's journey — home, space, page, search — weighted 15/25/45/15.
scripts/load-test.sh smoke        # 2 VUs, 10 s: is anything broken?
scripts/load-test.sh 200          # ramp to 200 VUs for 3 minutes

# One endpoint, 50 readers, 500 requests, with the latency distribution.
hey -c 50 -n 500 http://localhost:4000/
hey -c 50 -n 500 "http://localhost:4000/search?q=schema+migration"
```

`k6-load-tests/README.md` documents the profiles, the thresholds and what load
testing found on this repository before the reader work; the numbers in the next
section are the current ones.

### Reading a load report

* **Requests/sec** is throughput; **average** and **p95** are what one reader
  waits. They move in opposite directions as you add concurrency: read both.
* **A p95 far above the average** means queueing, not slow code: some requests
  wait for a connection from the pool, the BEAM scheduler, or a lock. Compare
  `-c 1` with `-c 50` on the same URL — if one reader is fast and fifty are not,
  the request is fine and the *capacity* is the problem.
* **429s** are the reader rate limiter, not the mirror: every `k6` VU shares one
  client IP, and the default allows 240 HTML requests a minute, so even one
  `hey -n 500` trips it. A run that reports a suspiciously flat 700 rps at 70 ms
  is usually measuring the limiter's 429s — check the status distribution before
  believing a number. Raise `CM_READER_RATE_LIMIT_PER_MINUTE` for the run.
* **500s with queue time** are the connection pool: `POOL_SIZE` sets how many
  statements can be in flight. `POOL_SIZE` is per replica and must fit Postgres'
  `max_connections` across all of them ([operations.md](operations.md)).
* **Timeouts and wild p99s with low CPU** usually mean the host is busy — another
  server, a test suite, a browser. Check the load average before believing a
  number; never run the suite and a load test at the same time.

Everything above is measured on a development server, which compiles on the fly
(CodeReloader), annotates every HEEx node (`debug_heex_annotations`) and runs
Tailwind/esbuild watchers. A release is meaningfully faster; compare releases to
releases and development to development.

## What it measured

Suite numbers are in-process requests against a warm mirror (1000 spaces ×
1000 pages), statements and bytes as the suite reports them. Load numbers are a
development server on a laptop that was also running an editor (load average
16), 50 concurrent readers, 500 requests per URL — treat them as shapes, not
absolutes. The 30 000-page column is 100 spaces × 300 pages of generated
content, searched by a phrase that appears in ~30 pages' prose.

| screen | statements | response | suite median | hey, 43 pages | hey, 30 000 pages |
| --- | --- | --- | --- | --- | --- |
| a page view | 16 | 48 KB | 3.9 ms | 686 rps, p95 85 ms | 720 rps, p95 84 ms |
| space overview | 13 | 35 KB | 4.4 ms | 518 rps, p95 142 ms | 215 rps, p95 341 ms |
| space catalog | 11 | 80 KB | 4.6 ms | 497 rps, p95 128 ms | 352 rps, p95 203 ms |
| home page | 15 | 36 KB | 6.5 ms | 545–580 rps, p95 109 ms | 516 rps, p95 187 ms |
| search | 18 | 93 KB | 470 ms | 410 rps, p95 163 ms | 170 rps, p95 464 ms |

And the journey `k6` drives, 200 readers for three minutes over the same
30 000 pages: 20 889 requests at 115 rps, p50 38 ms, p95 402 ms, p99 1 042 ms,
0 % failures (the profile's thresholds are p95 < 800 ms and p99 < 2 s).

Statement counts do not move with the size of the mirror; response sizes move a
little (a wider branch, more text); timings move with the data the way the
*queries* allow. Two things still scale: search, because `ts_rank_cd` scores
every match before it can sort them (a design question, not a query to trim),
and the first home page after a sync on a cold cache, which a sync now warms.

The same screens on the real site above (732 mirrored pages over 21 spaces,
same laptop and server): a page 513 rps at p95 115 ms, the space catalog 486 rps
at 129 ms, the home page 453 rps at 138 ms, search 381 rps at 168 ms, and the
space overview 273 rps at 214 ms — the shape of the generated-data columns, which
is the useful result: real content is not slower per request than a fixture of
the same size.

### Where the wall is

Those numbers are latency at a fixed concurrency; they say nothing about
capacity. The `throughput` profile asks for a fixed arrival rate and reports the
latency the mirror answers with — raise `RPS` until p95 breaks:

| requested | served | p50 | p95 | dropped iterations |
| --- | --- | --- | --- | --- |
| 200 rps | 242 rps | 188 ms | 418 ms | 0 |
| 300 rps | 343 rps | 1 318 ms | 2 541 ms | 596 |
| 400 rps | 339 rps | 2 924 ms | 4 372 ms | 4 233 |
| 800 rps | 299 rps | 7 238 ms | 10 085 ms | 22 717 |

Served stops rising around 300 rps and latency climbs from there: that is the
knee of one development server on one laptop, and it is queueing, not a slow
query (the p50 moves with it). A release with a pooled connection set sized to
Postgres is the number that matters for a deployment; measure it the same way.

```bash
k6 run -e PROFILE=throughput -e RPS=300 -e DURATION=60s \
  -e BASE_URL=http://localhost:4000 k6-load-tests/reader.js
```

## Things that look like performance problems and are not

* **The first request after a sync** on the home page used to be seconds at a
  million pages, because the totals were counted per request. They are cached
  per content version now (`Mirror.Counters`), and a sync recomputes them when it
  finishes.
* **A `:manual` sandbox and a million rows.** Seeding the suite's fixture takes
  minutes inside one transaction; the sandbox's default ownership timeout is two
  minutes, which is why the scale suite asks for a longer one. If you see
  `owner … timed out`, that is the fixture, not the mirror.
* **A cache that outlives a rolled-back transaction.** ETS is not transactional,
  so the suite clears `Mirror.Counters` before every test. A script that writes
  rows directly should call `Mirror.Counters.clear/0` too.
* **Search that finds everything.** Generated content shares a vocabulary, so a
  query for a common word matches most pages and looks slow; that is the ranking
  cost of a large result set, and a query for a page-specific phrase is the fair
  comparison.
