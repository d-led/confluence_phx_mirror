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

Two settings decide whether you are measuring the mirror or a guard rail: the
reader rate limit (every VU shares one client IP, so the default turns a 200-VU
run into `429`s — raise it for the test) and the connection pool, which is the
real ceiling per replica. Both, and how to read the report, are in
[performance.md](../docs/performance.md#part-2-load-against-a-running-server).
The data to point this at comes from the synthetic source; the same guide has the
commands.

## Reading a report

Three things explain almost every surprising number. The current measurements
and how to read a report in full are in
[performance.md](../docs/performance.md#part-2-load-against-a-running-server).

* **A flat, high rate with tiny latencies is the reader rate limiter.** Every VU
  shares one client address, so the default 240 HTML requests a minute answers
  `429` long before the mirror is busy. Check the status codes.
* **p95 far above the average is queueing**, not slow queries: the connection
  pool, the acceptor sockets, or the BEAM. Compare `-c 1` with `-c 50` on the
  same URL.
* **A contended host is noise.** Run the mirror as a release on a machine that
  is not also running k6, Postgres and a test suite.
