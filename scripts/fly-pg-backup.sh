#!/usr/bin/env bash
#
# Back up the mirror's Postgres to a file on this machine.
#
#   ./scripts/fly-pg-backup.sh                  # → backups/confluence-mirror-YYYYmmdd-HHMMSS.dump
#   ./scripts/fly-pg-backup.sh --format=plain   # SQL that psql can read
#   ./scripts/fly-pg-backup.sh --out /tmp/x     # somewhere else
#
# Two things this gets right that cost an afternoon otherwise:
#
#   * the connection string is the app's own — `fly ssh console` prints
#     DATABASE_URL out of the Machine that has it, so nobody pastes the database
#     password into a shell
#   * the client must match the server's major version (pg_dump refuses to dump
#     a newer server, and no flag makes that safe). The script asks the database
#     Machine which version it runs and looks for that pg_dump on PATH, in
#     postgresql@N from Homebrew, and in Debian's /usr/lib/postgresql/N.
#
# Restore with scripts/fly-pg-restore.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP=confluence-mirror-app
DB_APP=confluence-mirror-db
PORT=15432
FORMAT=custom
OUT=backups

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-app) DB_APP="${2:?--db-app needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --format)
      FORMAT="${2:?--format needs custom or plain}"
      if [[ $FORMAT != custom && $FORMAT != plain ]]; then
        echo "error: --format is custom or plain" >&2
        exit 64
      fi
      shift 2
      ;;
    -h | --help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; exit 64 ;;
  esac
done

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

dump_bin=$(find_client pg_dump) || {
  echo "error: no pg_dump $server_major here; the server runs $server_major" >&2
  echo "       brew install postgresql@$server_major   (or set PG_CLIENT_DIR)" >&2
  exit 1
}

url=${DATABASE_URL:-}
if [[ -z $url ]]; then
  # The secret is write-only to us, readable to the Machine.
  url=$(fly ssh console --app "$APP" --command 'printenv DATABASE_URL' 2>/dev/null |
    tr -d '\r' | grep -o 'postgres://[^[:space:]]*' | tail -1 || true)
fi
[[ -n $url ]] || { echo "error: no DATABASE_URL (is $APP deployed?)" >&2; exit 1; }

# Same credentials, through the tunnel: @host:port/ → @localhost:PORT/
local_url=$(printf '%s' "$url" | sed -E "s#@[^/]+/#@localhost:${PORT}/#")

mkdir -p "$OUT"
stamp=$(date +%Y%m%d-%H%M%S)
extension="dump"
[[ $FORMAT == plain ]] && extension="sql"
file="$OUT/confluence-mirror-${stamp}.${extension}"

echo "tunnelling to $DB_APP on localhost:$PORT (server $server_major)"
fly proxy "${PORT}:5432" --app "$DB_APP" > /dev/null 2>&1 &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
  if nc -z localhost "$PORT" 2>/dev/null; then break; fi
  sleep 0.5
done
nc -z localhost "$PORT" 2>/dev/null || { echo "error: the tunnel on $PORT never opened" >&2; exit 1; }

echo "dumping"
"$dump_bin" "--format=$FORMAT" --no-owner --no-acl --file "$file" "$local_url"

size=$(wc -c < "$file" | tr -d ' ')
[[ ${size:-0} -gt 0 ]] || { echo "error: the dump is empty" >&2; exit 1; }

echo "wrote $file ($(du -h "$file" | cut -f1))"
echo "restore: ./scripts/fly-pg-restore.sh $file"
