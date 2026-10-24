#!/bin/bash
# Keep the fill running until every chunk is done.
#
# A long fill stops for reasons that are not its own: the laptop sleeps, the
# network blips, the generator gives up mid-chunk. Every run picks up from the
# chunk list, so running it again is always the right move — this is the loop
# that keeps doing that, and it stops when `fill-confluence.sh` reports done.
#
#   CONFLUENCE_GENERATOR=~/src/confluence-test-data-generator \
#     nohup scripts/tooling/fill-forever.sh --pages 100000 >/dev/null 2>&1 &
#
# Everything lands in var/confluence-fill/supervisor.log; the per-chunk logs and
# progress.log next to it are unchanged.
set -uo pipefail
IFS=$'\n\t'

cd "$(dirname "$0")/../.." || exit 1

: "${CONFLUENCE_GENERATOR:?set CONFLUENCE_GENERATOR to the generator checkout}"
: "${CM_CONFLUENCE_SITE:?set CM_CONFLUENCE_SITE to the Confluence site}"
: "${CM_ATL_EMAIL:?set CM_ATL_EMAIL to the Atlassian account e-mail}"
: "${CM_ATL_TOKEN:?set CM_ATL_TOKEN to the API token of that account}"

out=var/confluence-fill
log=$out/supervisor.log
base_pause=${RESTART_PAUSE:-120}
max_restarts=${MAX_RESTARTS:-200}

mkdir -p "$out"

# Two generators on one prefix would race each other into duplicate titles.
if pgrep -f "fill-confluence.sh" >/dev/null; then
  echo "a fill is already running; stop it first (pkill -f fill-confluence.sh)" >&2
  exit 1
fi

pause=$base_pause
attempt=0

while :; do
  attempt=$((attempt + 1))
  started=$SECONDS
  echo "$(date '+%Y-%m-%d %H:%M:%S') attempt $attempt: filling" >>"$log"

  if scripts/tooling/fill-confluence.sh "$@" </dev/null >>"$log" 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') every chunk is done" >>"$log"
    exit 0
  fi

  if [ "$attempt" -ge "$max_restarts" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') stopped $attempt times; giving up" >>"$log"
    exit 1
  fi

  # A run that lasted minutes did real work and deserves a quick retry; one that
  # died at once is a sign of a broken setting, so slow down instead of hammering.
  if [ "$((SECONDS - started))" -ge 300 ]; then
    pause=$base_pause
  elif [ "$pause" -lt 600 ]; then
    pause=$((pause * 2))
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S') the fill stopped; restarting in ${pause}s" >>"$log"
  sleep "$pause"
done
