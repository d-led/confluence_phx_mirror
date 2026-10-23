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
# Cleanup: the generator truncates a prefix to six characters for the space
# key ("PERFLOAD1" becomes PERFLO1, PERFLO2, …), so a chunk number has to sit
# inside those six characters or every chunk collides with the first one. The
# chunk prefix is therefore a base of at most four characters plus a two-digit
# chunk number, and cleanup runs once per chunk prefix.
#
# Keep the base to four characters: "LOAD" + 01 gives LOAD01, the space key is
# LOAD011, LOAD012, … and chunk 02 gets LOAD021 onwards.

set -euo pipefail

cd "$(dirname "$0")/../.."

OUT_DIR="${OUT_DIR:-var/confluence-fill}"
PREFIX="${PREFIX:-LOAD}"
MAX_CHUNKS=99
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
  # Prefer the chunks this machine actually ran; fall back to the whole range so
  # a run whose logs are gone can still be removed.
  chunk_prefixes=""
  for log in "$OUT_DIR"/"$PREFIX"[0-9][0-9].log; do
    [ -e "$log" ] || continue
    chunk_prefixes="$chunk_prefixes $(basename "$log" .log)"
  done
  if [ -z "$chunk_prefixes" ]; then
    chunk_prefixes=$(for i in $(seq 1 "$MAX_CHUNKS"); do printf '%s%02d\n' "$PREFIX" "$i"; done)
  fi

  echo "Deleting generated spaces, one chunk prefix at a time (permanent, no trash)."
  for chunk_prefix in $chunk_prefixes; do
    run_generator --cleanup --prefix "$chunk_prefix" --yes 2>&1 |
      sed -n "s/.*Deleted \\([0-9]*\\/[0-9]*\\) space.*/$chunk_prefix: \\1/p"
  done
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

if [ "$chunks" -gt "$MAX_CHUNKS" ]; then
  echo "$pages pages needs $chunks chunks; the prefix scheme stops at $MAX_CHUNKS." >&2
  echo "Raise PAGES_PER_CHUNK (each chunk is a separate ~half-hour run)." >&2
  exit 1
fi

if [ "${#PREFIX}" -gt 4 ]; then
  echo "PREFIX=$PREFIX is longer than four characters; the space key keeps only" >&2
  echo "six and the chunk number needs the last two. Use e.g. PREFIX=LOAD." >&2
  exit 1
fi

echo "Plan: $pages pages in $chunks chunk(s) of $PAGES_PER_CHUNK, --count $total_count"
echo "      generator: $generator"
echo "      writing under $OUT_DIR"
echo "      space keys ${PREFIX}011 … ${PREFIX}${chunks}1 (chunk prefix + space number)"
echo

# What the tool itself intends to create, before it creates anything.
run_generator --count "$total_count" --spaces "$(( SPACES_PER_CHUNK * chunks ))" \
  "${content_only[@]}" --dry-run 2>&1 | sed -n 's/.*INFO -   /  planned /p'

if [ "$dry_run" -eq 1 ]; then
  printf '\n--dry-run: nothing written.\n'
  exit 0
fi

mkdir -p "$OUT_DIR"

for i in $(seq 1 "$chunks"); do
  chunk_prefix=$(printf '%s%02d' "$PREFIX" "$i")
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