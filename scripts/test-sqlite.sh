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
# It is a gate: `.github/workflows/ci.yml` runs it as its own job, beside the
# Postgres one, on every push and pull request. What it establishes:
#
#   * the schema set is applied by the `mix test` alias alone for this adapter
#     (`priv/repo/manual_migrations` are Postgres-shaped on purpose), which is
#     the same set the tool's own boot applies;
#   * `Mirror.pages_for_labels/2`, `Mirror.descendants/2`, the label macros, the
#     space tree and the mail budget all answer on both engines;
#   * what the tool genuinely cannot do is marked `:postgres_only` (Postgres
#     full-text and its query language, the manual migrations, the tablespace
#     card) and excluded here rather than skipped quietly — see
#     `test/test_helper.exs`.
#
# The differences it has caught so far, each of which was a bug on one engine
# and silent on the other: `LIMIT NULL` (a datatype error in SQLite), `OFFSET`
# without a `LIMIT` (a syntax error), `TRUNCATE`, `now()`, `EXISTS` returning
# 0/1 instead of a boolean, a list parameter compared whole against one element
# in `IN`, and a `NOT NULL` that only Postgres was told to drop.
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

# One test at a time. SQLite allows a single writer, and the suite's concurrency
# (fine on Postgres) turns into "Database busy" the moment two tests write; this
# is the same one-writer arrangement the tool itself runs with.
mix test --max-cases 1 "$@"
