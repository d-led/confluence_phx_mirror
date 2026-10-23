#!/usr/bin/env bash
# Fills a Confluence Cloud site with generated pages, for mirroring at scale.
#
# The generator is a third-party tool (rewind-community/confluence-test-data-
# generator): a Python REST client that creates spaces, pages and blog posts
# from Confluence's own content multipliers. This wrapper adds the parts that
# matter for a real site: it works in chunks, it keeps the run inside a free
# plan's file-storage cap, and it can delete everything it made.
#
#   CONFLUENCE_GENERATOR=~/src/confluence-test-data-generator \
#   CM_CONFLUENCE_SITE=https://acme.atlassian.net \
#   CM_ATL_EMAIL=you@acme.com CM_ATL_TOKEN=... \
#     scripts/tooling/fill-confluence.sh --pages 100000
#
#   scripts/tooling/fill-confluence.sh --pages 100000 --dry-run   # plan only
#   scripts/tooling/fill-confluence.sh --cleanup                  # delete it all
#
# Why chunks: the generator checkpoints per *phase*, so a crash during the page
# phase loses every page that run made — `--resume` redoes the phase, not the
# page. A chunk that dies costs `--pages-per-chunk`, not the whole run. Cloud's
# API is also the ceiling, not concurrency: measured ~1.2 pages a second at
# concurrency 5 and at 10, so plan ~25 hours for 100 000 pages.
#
# Why --content-only: the free plan's 2 GB is *file* storage. Pages and blog
# posts are unlimited text; attachments and their versions are what grows
# without bound (a 100 000-page plan at the default multipliers is ~410 000
# attachment objects). `--with-attachments` exists, and it will not fit.
#
# Cleanup: every space key starts with the first six characters of the prefix,
# so one command removes every chunk. Prefixes are uppercased for that reason.

set -euo pipefail

cd "$(dirname "$0")/../.."

OUT_DIR="${OUT_DIR:-var/confluence-fill}"
PREFIX="${PREFIX:-LOADTEST}"
PAGES_PER_CHUNK="${PAGES_PER_CHUNK:-2000}"
SPACES_PER_CHUNK="${SPACES_PER_CHUNK:-3}"
CONCURRENCY="${CONCURRENCY:-10}"
PAUSE="${PAUSE:-30}"
# The generator's `--count` is pages + blog posts, not pages. At the default
# "small" bucket a page is 15.97% of it; the dry run below prints the plan the
# tool actually intends, so a drift in its multipliers is visible before writing.
PAGE_SHARE="0.1597"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

mode=fill
pages=""
with_attachments=0
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup) mode=cleanup ;;
    --pages) pages="${2:?--pages needs a number}"; shift ;;
    --with-attachments) with_attachments=1 ;;
    --dry-run) dry_run=1 ;;
    -h | --help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
  shift
done

: "${CONFLUENCE_GENERATOR:?set CONFLUENCE_GENERATOR to a clone of confluence-test-data-generator}"
: "${CM_CONFLUENCE_SITE:?set CM_CONFLUENCE_SITE, e.g. https://acme.atlassian.net}"
: "${CM_ATL_EMAIL:?set CM_ATL_EMAIL to the Atlassian account e-mail}"
: "${CM_ATL_TOKEN:?set CM_ATL_TOKEN to the API token of that account}"

generator="$CONFLUENCE_GENERATOR/confluence_data_generator.py"
[ -f "$generator" ] || {
  echo "no confluence_data_generator.py under CONFLUENCE_GENERATOR=$CONFLUENCE_GENERATOR" >&2
  exit 1
}

export CONFLUENCE_API_TOKEN="$CM_ATL_TOKEN"

run_generator() {
  "$CONFLUENCE_GENERATOR/.venv/bin/python" "$generator" \
    --url "$CM_CONFLUENCE_SITE/wiki" \
    --email "$CM_ATL_EMAIL" \
    --prefix "$PREFIX" \
    "$@"
}

if [ "$mode" = cleanup ]; then
  echo "Deleting every space whose key starts with ${PREFIX:0:6} (permanent, no trash)."
  run_generator --cleanup --yes
  exit
fi

[ -n "$pages" ] || { echo "--pages is required (or --cleanup)" >&2; exit 1; }
case "$pages" in *[!0-9]*) echo "--pages must be a number" >&2; exit 1 ;; esac

if [ "$with_attachments" -eq 1 ]; then
  echo "WARNING: attachments and their versions count against file storage;" >&2
  echo "100 000 pages means ~410 000 attachment objects. Check the cap." >&2
  content_only=()
else
  content_only=(--content-only)
fi

total_count=$(python3 -c "print(round($pages / $PAGE_SHARE))")
chunk_count=$(python3 -c "print(round($PAGES_PER_CHUNK / $PAGE_SHARE))")
chunks=$(( (pages + PAGES_PER_CHUNK - 1) / PAGES_PER_CHUNK ))

echo "Plan: $pages pages in $chunks chunk(s) of $PAGES_PER_CHUNK, --count $total_count"
echo "      generator: $generator"
echo "      writing under $OUT_DIR, prefix ${PREFIX}1 … ${PREFIX}${chunks}"
echo

# What the tool itself intends to create, before it creates anything.
run_generator --count "$total_count" --spaces "$(( SPACES_PER_CHUNK * chunks ))" \
  "${content_only[@]}" --dry-run | sed -n 's/.*INFO -   /  planned /p'

if [ "$dry_run" -eq 1 ]; then
  printf '\n--dry-run: nothing written.\n'
  exit 0
fi

mkdir -p "$OUT_DIR"

for i in $(seq 1 "$chunks"); do
  chunk_prefix="${PREFIX}${i}"
  log="$OUT_DIR/${chunk_prefix}.log"

  if grep -q "Generation complete" "$log" 2>/dev/null; then
    echo "$(date +%H:%M:%S) $chunk_prefix already complete"
    continue
  fi

  echo "$(date +%H:%M:%S) $chunk_prefix: creating ~$PAGES_PER_CHUNK pages" |
    tee -a "$OUT_DIR/progress.log"

  run_generator \
    --count "$chunk_count" \
    --spaces "$SPACES_PER_CHUNK" \
    "${content_only[@]}" \
    --concurrency "$CONCURRENCY" \
    --prefix "$chunk_prefix" >"$log" 2>&1 || true

  created=$(grep -c "Created page" "$log" || true)
  echo "$(date +%H:%M:%S) $chunk_prefix: $created pages" | tee -a "$OUT_DIR/progress.log"

  [ "$i" -lt "$chunks" ] && sleep "$PAUSE"
done

echo
echo "Done. Mirror it with: mix confluence.sync --mode snapshot"
echo "Remove it with:      scripts/tooling/fill-confluence.sh --cleanup"
