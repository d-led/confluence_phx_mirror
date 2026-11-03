#!/usr/bin/env bash
#
# Opens the export tool.
#
#   scripts/start-desktop.sh               build whatever is stale, then open
#   scripts/start-desktop.sh --rebuild     rebuild the release and the shell first
#   scripts/start-desktop.sh --in-browser  serve the tool and open a browser
#                                          window instead, for machines with no
#                                          Rust toolchain
#   scripts/start-desktop.sh --where       print the workspace in use, then exit
#
# What it opens is the native window: `src-tauri`, which starts the Elixir
# release as its sidecar, reads the address that release prints, and points a
# webview at it. The window adds no behaviour — every screen is the sidecar's,
# which is also the binary a headless machine would run.

set -euo pipefail

cd "$(dirname "$0")/.."

name=confluence_phx_mirror
release="_build/desktop/rel/$name"
sidecar="$PWD/$release/bin/$name"
window="src-tauri/target/debug/confluence-export"

# Where a build's output goes. Kept rather than discarded: a build that fails
# after two minutes of silence is a build nobody can diagnose.
build_log="${TMPDIR:-/tmp}/confluence-export-build.log"

mode=open

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) mode=rebuild; shift ;;
    --in-browser) mode=browser; shift ;;
    --where) mode=where; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

build_release() {
  echo "building the desktop release… (about three seconds warm)"
  if ! MIX_ENV=desktop mix release --overwrite >"$build_log" 2>&1; then
    echo "the release could not be built. Last lines of $build_log:" >&2
    tail -20 "$build_log" >&2
    return 1
  fi
  echo "release built"
}

build_window() {
  echo "building the window… (about four seconds warm)"
  if ! cargo build --manifest-path src-tauri/Cargo.toml >"$build_log" 2>&1; then
    echo "the window could not be built. Last lines of $build_log:" >&2
    tail -20 "$build_log" >&2
    return 1
  fi
  echo "window built"
}

# Build every time. There used to be mtime comparisons here to skip a rebuild,
# and they were wrong in the one way that matters: the window carries its own
# copy of the release (`bundle.resources` in tauri.conf.json, refreshed by
# `cargo build`), so an Elixir-only change rebuilt `_build/desktop/rel` and left
# the window starting the release it had copied hours earlier. A warm build of
# both is about seven seconds — cheaper than one wrong answer.

# `eval` starts no applications, which is all this needs: reading the workspace
# touches a settings file and never the catalogue.
where() {
  "$sidecar" eval '
    alias ConfluencePhxMirror.Desktop.Settings

    IO.puts("folder:      #{Settings.root()}")
    IO.puts("catalogue:   #{Settings.database()}")
    IO.puts("attachments: #{Settings.blobs()}")
    IO.puts("site:        #{Settings.site() || "(not set)"}")
    IO.puts("account:     #{Settings.email() || "(bearer token)"}")
  '
}

open_in_browser() {
  local log url sidecar_pid
  log=$(mktemp -t confluence-export.XXXXXX)

  "$sidecar" start >"$log" 2>&1 &
  # The release script execs the VM, so this PID is the sidecar itself — and it
  # is the only way to stop it: `stop` is an RPC, and the sidecar runs with no
  # node name (see RELEASE_DISTRIBUTION below), so it answers "Cannot run
  # --rpc-eval if the node is not alive" and leaves the process behind.
  sidecar_pid=$!

  cleanup() {
    if [[ -n "$sidecar_pid" ]]; then
      kill "$sidecar_pid" 2>/dev/null || true
    fi
    rm -f "$log"
  }
  trap cleanup EXIT INT TERM

  url=""
  for _ in $(seq 1 150); do
    url=$(sed -n 's/^desktop ui: //p' "$log" 2>/dev/null | head -1)
    if [[ -n "$url" ]]; then break; fi
    sleep 0.1
  done

  if [[ -z "$url" ]]; then
    echo "the tool did not start:" >&2
    tail -20 "$log" >&2
    exit 1
  fi

  echo "desktop ui: $url"
  open "$url"
  wait
}

if [[ "$mode" == where ]]; then
  build_release
  where
  exit 0
fi

build_release

if [[ "$mode" == rebuild ]] || [[ "$mode" == open ]]; then
  built_window=1
  build_window || built_window=0
fi

if [[ "$mode" == browser ]]; then
  open_in_browser
  exit 0
fi

# The shell is told where the sidecar is, absolutely: it would otherwise resolve
# a relative path against whatever directory it happened to be started in.
export CONFLUENCE_EXPORT_SIDECAR="$sidecar"

# No peers to cluster with. A distributed release has a fixed node name, so a
# second launch fails with "the name ... is in use by another Erlang node" —
# which is how the window ends up aborting: the sidecar never says where it
# listens. The `--in-browser` path starts the release from this script too.
export RELEASE_DISTRIBUTION=none

if [[ "${built_window:-1}" == 0 ]]; then
  echo "the native window could not be built (is cargo installed?)" >&2
  echo "opening the tool in a browser window instead" >&2
  open_in_browser
  exit 0
fi

# `exec` here would replace the shell with the window, so a hang shows nothing
# and an abort shows nothing either. Run it, say what happened, and pass the
# status on: a launcher that fails silently is worse than one that fails.
echo "opening the window…"
echo "  window:  $window"
echo "  sidecar: $sidecar"
echo "The window starts the sidecar, waits for the address it prints, and loads it."
echo "Its output follows. Ctrl-C stops both."

"$window"
status=$?

echo "the window exited with status $status" >&2
exit $status
