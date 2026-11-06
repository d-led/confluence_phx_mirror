#!/usr/bin/env bash
# Mutation testing, scoped to the functions the CRAP ranking already flags.
#
#   scripts/mutator.sh              run, or say what is missing
#   scripts/mutator.sh --targets    only print what it would scope to
#
# Why scoped: a mutation run compiles the tree, then runs the suite once per
# mutant. Across this application that is hours, and a run nobody waits for
# teaches nothing. The CRAP ranking already names the functions where a missed
# mutant costs most — high complexity, thin coverage — so those are the files
# worth mutating first.
#
# Why Muzak and not Mutare: Mutare is faster because it injects every mutation
# into one AST build and flips a `:persistent_term` switch to activate one. That
# is node-global state deciding what a test run sees, which is exactly the class
# of thing that makes this suite flaky (see the `people` fixture fix) and it
# cannot work beside async tests. Muzak runs the suite as it is, stops at the
# first failure per mutant, and caps a run at 25 mutants, which is a bounded
# check an operator can actually wait for. Muex is the third option and the most
# clever about which mutants matter; it is too young to be the first tool a
# repository depends on.
set -euo pipefail

cd "$(dirname "$0")/.."

targets=$(mktemp)
trap 'rm -f "$targets"' EXIT

MIX_ENV=test mix complexity 2>/dev/null |
  awk -F'[[:space:]]*\\|[[:space:]]*' '
    NF == 7 && $6 ~ /[0-9]/ && $6 + 0 >= 10 { print $1 }
  ' | sort -u >"$targets"

count=$(wc -l <"$targets" | tr -d ' ')

if [[ ${1:-} == "--targets" ]]; then
  echo "files with a function at CRAP 10 or above ($count):"
  sed 's/^/  /' "$targets"
  exit 0
fi

if ! mix help muzak >/dev/null 2>&1; then
  cat <<EOF
muzak is not a dependency of this project yet.

To turn it on, in this order:

  1. mix.exs, deps/0:      {:muzak, "~> 1.0", only: [:dev, :test]}
  2. mix deps.get
  3. scripts/mutator.sh

It caps a run at 25 mutants and stops each at the first failing test, so the
first run is minutes, not hours. Scope it further with its own options once it
is here: \`mix help muzak\`.

Meanwhile, the files a first run should point at — $count of them, chosen by the
same ranking the quality gate prints:
EOF
  sed 's/^/  /' "$targets"
  exit 2
fi

echo "mutating $count file(s) at CRAP 10 or above — a run is capped at 25 mutants"
mix muzak "$@"
