# Reader load tests (k6)

Read-only load against a mirror of real content. Anonymous readers: no sign-in,
no session, no cookies.

```bash
scripts/load-test.sh            # smoke, 200, 2000
scripts/load-test.sh smoke 200  # pick profiles
BASE_URL=http://mirror:4000 scripts/load-test.sh 200
```

Profiles: `smoke` (2 VUs, 10 s), `200` (ramp to 200 VUs, 3 min), `2000` (ramp to
2000 VUs, 5 min). Each run writes `var/k6/<profile>-<stamp>.json` and `.txt`,
and the script prints one table across the runs (needs `jq`).

The journey per iteration is what a reader does: home, a space, a page, or a
search — weighted 15/25/45/15. Targets are discovered in `setup()` from
`/wiki/rest/api/space` and `/wiki/rest/api/content`, so the test reads whatever
the mirror actually holds.

Thresholds: `http_req_failed < 1%`, p95 < 800 ms, p99 < 2 s.

## Before you run it

Two settings of the mirror decide whether you are measuring the mirror or the
guard rails:

* **Reader rate limit.** `CM_READER_RATE_LIMIT_PER_MINUTE` (default 300/admin,
  see `docs/configuration.md`) is per client. Every k6 VU shares one client, so
  the default turns a 200-VU run into 94% `429`. Raise it for the test:
  `CM_READER_RATE_LIMIT_PER_MINUTE=600000`.
* **Connection pool.** `POOL_SIZE` (default 20, per replica) is the real
  ceiling: ~15 queries per page view means a small pool saturates long before
  the CPU does, and p95 goes from 114 ms to 10 s in queue time (with `500`s once
  the queue gives up). Size it for the concurrency you expect —
  `replicas × POOL_SIZE` must fit Postgres' `max_connections` — and shrink the
  per-request query count, which is the fix worth making (see the home page's
  per-space queries in `query_budget_test.exs`).

## What it measured on 2026-10-22 (dev machine, live site, 43 pages)

| profile | requests | p95 | p99 | failures | note |
| --- | --- | --- | --- | --- | --- |
| smoke | 20 | 41 ms | 46 ms | 0% | |
| 200 | 14 756 | 114 ms | 314 ms | 5.6% (all `429`) | rate limiter, not the mirror |
| 200 | 4 382 | 10 190 ms | 23 628 ms | 1.2% (`500` from DB queue) | `POOL_SIZE=10` exhausted |
| 200 | 2 248 | 37 101 ms | 40 723 ms | 0.7% | `POOL_SIZE=40`, but the run shared the host with another server and a test suite: not a valid number |

So: a small pool saturates before 200 concurrent readers, and the queue, not the
queries, is what a reader would feel.

**Measure on a clean host.** Run the mirror as a release (`MIX_ENV=prod`,
`PHX_SERVER=true`) on a machine that is not also running k6, Postgres and a test
suite; dev mode adds the code reloader and per-request logging, and two servers
on one host share the database pool. Numbers taken on a contended laptop are
noise, which is what the `POOL_SIZE=40` row above demonstrates.

What to fix before expecting capacity to scale: `POOL_SIZE` per replica (see
`docs/operations.md`), and the home page's per-space queries — the N+1 pinned in
`query_budget_test.exs`.
