#!/usr/bin/env bash
#
# Opens the export tool: builds the release if it is missing, starts it, and
# opens its window.
#
#   scripts/start-desktop.sh              open the tool
#   scripts/start-desktop.sh --rebuild    build first, then open
#   scripts/start-desktop.sh --where      print the workspace in use, then exit
#
# This runs the compiled release, not `mix` and not a REPL: what it opens is the
# artifact a person would install. The window is the page the tool serves, in an
# app-style window of whichever browser is present. The native shell that
# removes that dependency is the next piece of work, and it needs this binary to
# exist first, because the binary is what the shell launches.

set -euo pipefail

cd "$(dirname "$0")/.."

name=confluence_phx_mirror
release="_build/desktop/rel/$name"
binary="$release/bin/$name"

mode=open

usage() {
  sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) mode=rebuild; shift ;;
    --where) mode=where; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

build() {
  echo "building the desktop release…"
  MIX_ENV=desktop mix release --overwrite >/dev/null
  echo "built"
}

# `eval` starts no applications, which is all this needs: reading the workspace
# touches a settings file and never the catalogue.
where() {
  "$binary" eval '
    alias ConfluencePhxMirror.Desktop.Settings

    IO.puts("id:          #{Settings.id()}")
    IO.puts("folder:      #{Settings.root()}")
    IO.puts("catalogue:   #{Settings.database()}")
    IO.puts("attachments: #{Settings.blobs()}")
    IO.puts("site:        #{Settings.site() || "(not set)"}")
    IO.puts("account:     #{Settings.email() || "(bearer token)"}")
  '
}

# An app-style window where a Chromium browser is installed: no address bar, no
# tabs, its own entry in the dock. Otherwise the default browser, which is worse
# and always works.
open_window() {
  local url=$1

  if [[ "$(uname)" == Darwin ]]; then
    for app in "Google Chrome" "Microsoft Edge" "Brave Browser" "Chromium"; do
      if [[ -d "/Applications/$app.app" ]]; then
        open -na "$app" --args --app="$url"
        return
      fi
    done
    open "$url"
  elif command -v xdg-open >/dev/null; then
    xdg-open "$url"
  else
    open "$url"
  fi
}

case "$mode" in
  where)
    [[ -x "$binary" ]] || build
    where
    ;;
  open | rebuild)
    if [[ "$mode" == rebuild ]] || [[ ! -x "$binary" ]]; then
      build
    fi

    log=$(mktemp -t confluence-export.XXXXXX)

    # Stopped on the way out however the script ends: a closed window over a
    # server still running is a port nobody can find again.
    cleanup() {
      "$binary" stop >/dev/null 2>&1 || true
      rm -f "$log"
    }
    trap cleanup EXIT INT TERM

    "$binary" start >"$log" 2>&1 &

    # The port is whichever the OS granted, so it is read from the tool's own
    # output rather than guessed.
    url=""
    for _ in $(seq 1 150); do
      url=$(sed -n 's/^desktop ui: //p' "$log" 2>/dev/null | head -1)
      if [[ -n "$url" ]]; then
        break
      fi
      sleep 0.1
    done

    if [[ -z "$url" ]]; then
      echo "the tool did not start:" >&2
      tail -20 "$log" >&2
      exit 1
    fi

    echo "desktop ui: $url"
    open_window "$url"

    wait
    ;;
esac
