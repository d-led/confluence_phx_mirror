#!/usr/bin/env bash
#
# The quality report: static analysis, the suite with coverage, and the CRAP
# ranking, in the order that fails fastest. Read-only — it never formats, never
# rewrites the lockfile, and never leaves a file behind.
#
#   scripts/quality.sh              everything CI runs on a push
#   scripts/quality.sh --fast       static analysis only: no database, no tests
#   scripts/quality.sh --no-tests   reuse the coverage already exported, re-rank
#   scripts/quality.sh --image      additionally build the image and check the user
#                                   it runs as (slow; CI does it for a release)
#   scripts/quality.sh --top 20     how many CRAP entries to rank (default 8)
#
# Exit status is non-zero if any gate fails, so it can sit in a pipeline.

set -euo pipefail

cd "$(dirname "$0")/.."

fast=0
tests=1
image=0
top=8

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast) fast=1; shift ;;
    --no-tests) tests=0; shift ;;
    --image) image=1; shift ;;
    --top) top="${2:?--top needs a number}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

# The CRAP threshold lives in mix.exs, next to the alias that applies it.
threshold=$(grep -o 'max-score [0-9]\+' mix.exs | awk 'NR == 1 { print $2 }')
threshold=${threshold:-30}

report=$(mktemp -t quality-report.XXXXXX)
trap 'rm -f "$report"' EXIT

failed=0
summary=()

banner() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

record() {
  local name=$1 status=$2 detail=${3:-}
  if [[ $status -eq 0 ]]; then
    summary+=("$(printf '  %-10s ok    %s' "$name" "$detail")")
  else
    summary+=("$(printf '  %-10s FAIL  %s' "$name" "$detail")")
    failed=1
  fi
}

first_lines() { sed -n "1,${1}p"; }

finish() {
  printf '\n\033[1m== summary ==\033[0m\n'
  printf '%s\n' "${summary[@]}"
  if [[ $failed -ne 0 ]]; then
    echo "quality: FAILED" >&2
    exit 1
  fi
  echo "quality: ok"
  exit 0
}

# ---------------------------------------------------------------------------
# Static analysis: compile, unused deps, format, credo, sobelow
# ---------------------------------------------------------------------------

banner "lint"
if mix lint >"$report" 2>&1; then
  record lint 0 "$(grep -E 'mods/funs, found no issues' "$report" | tail -1)"
else
  tail -n 40 "$report"
  record lint 1 "see above"
  # Nothing below is worth running on a tree that does not compile or lint.
  finish
fi

if [[ $fast -eq 1 ]]; then
  finish
fi

# ---------------------------------------------------------------------------
# The suite, with the coverage export the complexity gate reads
# ---------------------------------------------------------------------------

if [[ $tests -eq 1 ]]; then
  banner "cover"
  if mix cover >"$report" 2>&1; then
    record cover 0 "$(grep -E '^Result:' "$report" | tail -1)"
  else
    grep -E '^\s+[0-9]+\) test' "$report" | first_lines 20 || true
    tail -n 20 "$report"
    record cover 1 "see above"
  fi
fi

# ---------------------------------------------------------------------------
# CRAP: complexity squared by missing coverage, ranked per application tree
# ---------------------------------------------------------------------------

banner "complexity"
crap_status=0
mix complexity >"$report" 2>&1 || crap_status=$?

ranked=$(awk -F'[[:space:]]*\\|[[:space:]]*' '
  NF == 7 && $6 ~ /[0-9]/ && $6 + 0 > 0 {
    printf "%7.2f  %s %s  (complexity %s, coverage %s)\n", $6 + 0, $1, $3, $4, $5
  }
' "$report" | sort -rn | first_lines "$top")

if [[ -n $ranked ]]; then
  echo "top $top by CRAP — score, file, function, what drives it:"
  printf '%s\n' "$ranked" | sed 's/^/  /'
fi

per_file=$(awk -F'[[:space:]]*\\|[[:space:]]*' '
  NF == 7 && $6 ~ /[0-9]/ && $6 + 0 > 0 {
    file = $1
    score = $6 + 0
    if (score > worst[file]) {
      worst[file] = score
      function_of[file] = $3
      why[file] = "(complexity " $4 ", coverage " $5 ")"
    }
  }
  END {
    for (file in worst)
      printf "%7.2f  %s  %s %s\n", worst[file], file, function_of[file], why[file]
  }
' "$report" | sort -rn | first_lines "$top")

if [[ -n $per_file ]]; then
  echo "worst per file — score, file, its worst function:"
  printf '%s\n' "$per_file" | sed 's/^/  /'
fi

per_tree=$(awk -F'[[:space:]]*\\|[[:space:]]*' '
  NF == 7 && $6 ~ /[0-9]/ {
    split($1, parts, "/")
    tree = parts[1] "/" parts[2]
    if ($6 + 0 > worst[tree]) worst[tree] = $6 + 0
  }
  END { for (tree in worst) printf "%7.2f  %s\n", worst[tree], tree }
' "$report" | sort -rn)

if [[ -n $per_tree ]]; then
  echo "worst per tree:"
  printf '%s\n' "$per_tree" | sed 's/^/  /'
fi

worst=$(awk -F'|' 'NF == 7 && $6 ~ /[0-9]/ { if ($6 + 0 > w) w = $6 + 0 } END { printf "%.2f", w }' "$report")
offenders=$(awk -F'|' -v t="$threshold" 'NF == 7 && $6 ~ /[0-9]/ && $6 + 0 > t { n++ } END { print n + 0 }' "$report")

if [[ $crap_status -eq 0 ]]; then
  record complexity 0 "worst ${worst:-0.00}, threshold $threshold"
else
  printf '\n'
  grep -E 'threshold failed|score=' "$report" | first_lines 20 || true
  record complexity 1 "worst ${worst:-?}, $offenders function(s) above $threshold"
fi

# ---------------------------------------------------------------------------
# The image, built and started as the user it claims to be. Five minutes and
# the half whose breakage `docker build .` finds anyway, so it is asked for
# rather than assumed — CI builds it for a release tag or on request. The Trivy
# scan stays in CI: fourteen seconds there, and a database download here.
# ---------------------------------------------------------------------------

if [[ $image -eq 1 ]]; then
  banner "image"

  if ! command -v docker >/dev/null 2>&1; then
    record image 1 "docker is not on PATH"
  else
    tag="confluence-mirror-quality:$$"

    if docker build -q -t "$tag" . >"$report" 2>&1; then
      uid=$(docker run --rm --entrypoint /usr/bin/id "$tag" -u 2>>"$report") || uid=unknown

      if [[ $uid == 10001 ]]; then
        record image 0 "built, runs as uid $uid"
      else
        record image 1 "runs as uid $uid, not 10001"
      fi
    else
      tail -n 30 "$report"
      record image 1 "does not build"
    fi

    docker image rm -f "$tag" >/dev/null 2>&1 || true
  fi
fi

finish
