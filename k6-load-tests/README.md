# Reader load tests (k6)

Read-only load against a mirror of real content. Anonymous readers: no sign-in,
no session, no cookies.

**Needs:** `k6` (`brew install k6`) and a healthy mirror at `BASE_URL/health`.
The script refuses to start without either.

```bash
scripts/load-test.sh            # smoke, 200, 2000
scripts/load-test.sh smoke 200  # pick profiles
BASE_URL=http://mirror:4000 scripts/load-test.sh 200
```

Profiles: `smoke` (2 VUs, 10 s), `200` (ramp to 200 VUs, 3 min), `2000` (ramp to
2000 VUs, 5 min). Each run writes `var/k6/<profile>-<stamp>.json` and `.txt`,
and the script prints one table across the runs (needs `jq`).

**Done when** the table shows `http_req_failed` under 1% and p95 under 800 ms. A
higher p95 with tiny latencies is almost always the reader rate limiter — see
below.

The journey per iteration is what a reader does: home, a space, a page, or a
search — weighted 15/25/45/15. Targets are discovered in `setup()` from
`/wiki/rest/api/space` and `/wiki/rest/api/content`, so the test reads whatever
the mirror actually holds.

Thresholds: `http_req_failed < 1%`, p95 < 800 ms, p99 < 2 s.

## Before and after a run

Two settings decide whether you are measuring the mirror or a guard rail: the
reader rate limit (every VU shares one client address, so the default turns a
200-VU run into `429`s — raise it for the test) and the connection pool, which is
the real ceiling per replica. The knobs, how to build the test data and the
current numbers are in
[performance.md](../docs/performance.md#part-2-load-against-a-running-server).

Three things explain almost every surprising report:

* **A flat, high rate with tiny latencies is the reader rate limiter.** The
  default allows 240 HTML requests a minute per address, so the limiter answers
  `429` long before the mirror is busy. Check the status codes.
* **p95 far above the average is queueing**, not slow queries: the connection
  pool, the acceptor sockets, or the BEAM. Compare `-c 1` with `-c 50` on the
  same URL.
* **A contended host is noise.** Run the mirror as a release on a machine that
  is not also running k6, Postgres and a test suite.
