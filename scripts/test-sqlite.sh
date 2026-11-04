#!/usr/bin/env bash
#
# The same suite against the other engine.
#
# The deployment runs Postgres; the desktop tool runs SQLite, on the same code and
# the same migrations. Anything the two spell differently — `LIMIT NULL` is "no
# limit" to one and a datatype error to the other, `OFFSET` alone is fine in one
# and a syntax error in the other, `@>`/`&&`/`= ANY`/`cardinality` are the first
# engine's spelling of array questions, and a column Postgres was told to relax
# stays `NOT NULL` in SQLite — is invisible to a suite that only ever sees one of
# them. Five such differences have already shipped a bug each.
#
# The adapter is `Application.compile_env` in `ConfluencePhxMirror.Repo`, so this
# has its own build path and its own database file; nothing it writes is the
# Postgres run's business.
#
# It is **not a gate yet**, and that is the honest state of it. What it reports
# today, in the order it reports it:
#
#   * `priv/repo/manual_migrations` — Postgres-shaped on purpose, so the `mix
#     test` alias applies the schema set alone for this adapter (the same set the
#     tool's own boot applies);
#   * ported, and green on both engines: `Mirror.pages_for_labels/2` (`labels @>`
#     and `&&` → `json_each`) and `Mirror.descendants/2` (`= ANY`, `cardinality`
#     → `json_each`, `json_array_length`);
#   * still open: the boot-time pull mirrors an attachment whose `confluence_id`
#     the schema types `:string` while the column is an integer on this engine —
#     and whatever sits behind it, which this script exists to show.
#
# Make it green, then add it to `.github/workflows/ci.yml` as a second job beside
# the Postgres one: same suite, two engines, in parallel. Until then the job would
# be a gate that always fails, which is worse than no gate.
#
#   scripts/test-sqlite.sh                     the whole suite
#   scripts/test-sqlite.sh test/a_test.exs     one file, while porting
set -euo pipefail

cd "$(dirname "$0")/.."

export CM_TEST_ADAPTER=sqlite
export MIX_BUILD_PATH=_build/sqlite
export MIX_ENV=test

# A file, not `:memory:`: the sandbox gives every test its own connection, and
# they all have to see the same database. Starting from nothing means a stale
# schema cannot be mistaken for a passing run.
rm -f tmp/test.db tmp/test.db-wal tmp/test.db-shm

mix test "$@"
