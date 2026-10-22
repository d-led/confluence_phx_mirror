#!/usr/bin/env bash
# Runs the reader load profiles and keeps their reports.
#
#   scripts/load-test.sh                 # smoke, then 200, then 2000
#   scripts/load-test.sh smoke 200       # only those profiles
#   BASE_URL=http://mirror.example.com scripts/load-test.sh 200
#
# Each profile writes var/k6/<profile>-<timestamp>.json (summary) and .txt
# (k6's own report). The summaries are what the table at the end reads, so two
# runs can be compared without opening k6's output.

set -euo pipefail

cd "$(dirname "$0")/.."

BASE_URL="${BASE_URL:-http://localhost:4000}"
OUT_DIR="${OUT_DIR:-var/k6}"
PROFILES=("$@")
if [ ${#PROFILES[@]} -eq 0 ]; then
  PROFILES=(smoke 200 2000)
fi

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6 is not installed: brew install k6 (or see https://k6.io/docs/get-started/installation/)" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "Mirror: $BASE_URL"
if ! curl -sf -o /dev/null "$BASE_URL/health"; then
  echo "No healthy mirror at $BASE_URL/health — start it (mix phx.server) first." >&2
  exit 1
fi

for profile in "${PROFILES[@]}"; do
  stamp="$(date +%Y%m%d-%H%M%S)"
  echo
  echo "== $profile ($stamp)"

  k6 run \
    -e "BASE_URL=$BASE_URL" \
    -e "PROFILE=$profile" \
    --summary-export "$OUT_DIR/$profile-$stamp.json" \
    k6-load-tests/reader.js | tee "$OUT_DIR/$profile-$stamp.txt"
done

echo
echo "Summaries in $OUT_DIR:"
ls -1 "$OUT_DIR"/*.json 2>/dev/null | tail -5

# One table across the runs, if jq is around; otherwise the .txt files have it.
if command -v jq >/dev/null 2>&1; then
  echo
  printf '%-10s %10s %8s %9s %9s %8s\n' profile requests rps p95_ms p99_ms errors
  for file in "$OUT_DIR"/*.json; do
    jq -r \
      --arg profile "$(basename "$file" | cut -d- -f1)" \
      '[
         $profile,
         (.metrics.http_reqs.count // 0),
         (.metrics.http_reqs.rate // 0),
         (.metrics.http_req_duration["p(95)"] // 0),
         (.metrics.http_req_duration["p(99)"] // 0),
         ((.metrics.http_req_failed.rate // .metrics.http_req_failed.value // 0) * 100)
       ] | @tsv' "$file"
  done | awk -F'\t' '{printf "%-10s %10d %8.1f %9.1f %9.1f %7.2f%%\n", $1, $2, $3, $4, $5, $6}'
fi
