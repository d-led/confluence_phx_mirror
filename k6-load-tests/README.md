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
* **Connection pool.** `POOL_SIZE` (default 10) is the real ceiling: ~15 queries
  per page view means a handful of readers saturate it and p95 goes from 114 ms
  to 10 s in queue time. Size it for the concurrency you expect (or shrink the
  per-request query count — which is the fix worth making).

## What it measured on 2026-10-22 (dev machine, live site, 43 pages)

| profile | requests | p95 | p99 | failures | note |
| --- | --- | --- | --- | --- | --- |
| smoke | 20 | 41 ms | 46 ms | 0% | |
| 200 | 14 756 | 114 ms | 314 ms | 5.6% (all `429`) | rate limiter, not the mirror |
| 200 | 4 382 | 10 190 ms | 23 628 ms | 1.2% (`500` from DB queue) | `POOL_SIZE=10` exhausted |

So: one dev-sized pool saturates before 200 concurrent readers, and the queue,
not the queries, is what a reader would feel. Raise `POOL_SIZE`, then rerun —
and shrink the home page's per-space queries, which is the known N+1 in
`query_budget_test.exs`.
