#!/usr/bin/env bash
#
# Restore a dump made by scripts/fly-pg-backup.sh into the mirror's Postgres.
#
#   ./scripts/fly-pg-restore.sh backups/confluence-mirror-20261023-1930.dump
#   ./scripts/fly-pg-restore.sh --into confluence-mirror-db-5g <file>
#
# This overwrites what the database holds: `pg_restore --clean --if-exists`
# drops each object before creating it, and `--single-transaction` means a
# failure leaves the old data in place instead of half of each.
#
# The mirror's Machine is stopped for the duration and started again afterwards
# — a mirror writing into a schema that is being replaced produces a page of
# errors nobody can use. `--keep-running` skips that when you know better.
#
# `--into` restores into a *different* database app, which is how a cluster gets
# replaced: dump, create the replacement, restore, re-attach, redeploy. The
# client version has to match the target server, exactly as for the backup.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP=confluence-mirror-app
DB_APP=confluence-mirror-db
PORT=15432
KEEP_RUNNING=0
file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:?--app needs a value}"; shift 2 ;;
    --into) DB_APP="${2:?--into needs a database app}"; shift 2 ;;
    --keep-running) KEEP_RUNNING=1; shift ;;
    -h | --help) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; exit 64 ;;
    *) file="$1"; shift ;;
  esac
done

[[ -n $file ]] || { echo "error: which dump? (see --help)" >&2; exit 64; }
[[ -f $file ]] || { echo "error: no such file: $file" >&2; exit 1; }

command -v fly > /dev/null || { echo "error: the fly CLI is not installed" >&2; exit 1; }
fly auth whoami > /dev/null 2>&1 || { echo "error: run: fly auth login" >&2; exit 1; }
command -v nc > /dev/null || { echo "error: nc is needed to wait for the tunnel" >&2; exit 1; }

server_major=$(fly ssh console --app "$DB_APP" --command "printenv PG_MAJOR_VERSION" 2>/dev/null |
  tr -d '\r' | grep -E '^[0-9]+$' | head -1 || true)
[[ -n $server_major ]] || { echo "error: cannot read the server's major version from $DB_APP" >&2; exit 1; }

find_client() {
  local tool=$1 candidate
  for candidate in "${PG_CLIENT_DIR:+$PG_CLIENT_DIR/$tool}" \
    "$(command -v "$tool" 2>/dev/null || true)" \
    "/opt/homebrew/opt/postgresql@$server_major/bin/$tool" \
    "/usr/lib/postgresql/$server_major/bin/$tool"; do
    if [[ -n $candidate && -x $candidate ]] &&
      "$candidate" --version 2>/dev/null | grep -qE "[^0-9]$server_major\."; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

case "$file" in
  *.sql) tool=psql ;;
  *) tool=pg_restore ;;
esac

restore_bin=$(find_client "$tool") || {
  echo "error: no $tool $server_major here; the server runs $server_major" >&2
  echo "       brew install postgresql@$server_major   (or set PG_CLIENT_DIR)" >&2
  exit 1
}

url=${DATABASE_URL:-}
if [[ -z $url ]]; then
  url=$(fly ssh console --app "$APP" --command 'printenv DATABASE_URL' 2>/dev/null |
    tr -d '\r' | grep -o 'postgres://[^[:space:]]*' | tail -1 || true)
fi
[[ -n $url ]] || { echo "error: no DATABASE_URL (is $APP deployed?)" >&2; exit 1; }

local_url=$(printf '%s' "$url" | sed -E "s#@[^/]+/#@localhost:${PORT}/#")

machine=""

stop_app() {
  [[ $KEEP_RUNNING -eq 1 ]] && return 0

  machine=$(fly machine list --app "$APP" --json 2>/dev/null |
    grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  [[ -n $machine ]] || return 0

  echo "stopping $machine"
  fly machine stop "$machine" --app "$APP" > /dev/null
}

trap '[[ -n $machine ]] && fly machine start "$machine" --app "$APP" > /dev/null' EXIT

fly proxy "${PORT}:5432" --app "$DB_APP" > /dev/null 2>&1 &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true; [[ -n $machine ]] && fly machine start "$machine" --app "$APP" > /dev/null' EXIT

for _ in $(seq 1 40); do
  if nc -z localhost "$PORT" 2>/dev/null; then break; fi
  sleep 0.5
done
nc -z localhost "$PORT" 2>/dev/null || { echo "error: the tunnel on $PORT never opened" >&2; exit 1; }

stop_app

echo "restoring $file into $DB_APP (server $server_major)"
case "$tool" in
  psql) "$restore_bin" --quiet --set ON_ERROR_STOP=1 --dbname "$local_url" --file "$file" ;;
  *) "$restore_bin" --no-owner --no-acl --clean --if-exists --single-transaction --dbname "$local_url" "$file" ;;
esac

echo "restored"
