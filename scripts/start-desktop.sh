#!/usr/bin/env bash
#
# Opens the export tool.
#
#   scripts/start-desktop.sh               build both halves, then open the window
#   scripts/start-desktop.sh --in-browser  build the release, then serve it here
#   scripts/start-desktop.sh --where       build the release, then print the workspace
#   scripts/start-desktop.sh --app         build the .app bundle, then open that
#
# What it opens is the native window: `src-tauri`, which starts the Elixir
# release as its sidecar, reads the address that release prints, and points a
# webview at it. The window adds no behaviour — every screen is the sidecar's,
# which is also the binary a headless machine runs (`--in-browser`).
#
# Nothing here is captured, backgrounded or piped: every command writes to this
# terminal as it runs, and the first one that fails stops the script with that
# command's status and that command's own complaint.

set -euo pipefail

cd "$(dirname "$0")/.."

name=confluence_phx_mirror
release="_build/desktop/rel/$name"
sidecar="$PWD/$release/bin/$name"
window="src-tauri/target/debug/confluence-export"

# The double-clickable app: the release window plus a copy of the release
# inside it, so it runs without this checkout and without this script.
bundle="src-tauri/target/release/bundle/macos/Confluence Export.app"

# Bundling is a separate config, merged only for `--app`. `bundle.active` in the
# main config makes `cargo build` (the debug window this script opens every run)
# fail in tauri-build's resource phase with "Permission denied (os error 13)",
# and the debug window has no use for a bundle.
bundle_config="src-tauri/tauri.bundle.conf.json"

# Nothing about the build is configured from here. The two exports further down
# are for the running app, and they are set after the builds on purpose: cargo
# re-runs a build script when a variable it reads changes, so a variable that
# only the app needs has no business in the build's environment.

mode=open

usage() {
  echo "scripts/start-desktop.sh [--in-browser | --where | --app]"
  echo
  echo "  (no flags)     build the release and the window, then open the window"
  echo "  --in-browser   build the release, then serve it in this terminal"
  echo "  --where        build the release, then print the workspace in use"
  echo "  --app          build the .app bundle, then open that"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-browser) mode=browser; shift ;;
    --where) mode=where; shift ;;
    --app) mode=app; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "unknown option: $1"
      usage
      exit 64
      ;;
  esac
done

# One line before and one after, so a long build is visibly alive and a slow
# step is visibly the slow one. No redirection: the tools' own output is the
# thing worth reading when something goes wrong.
steps=0
run() {
  local started=$SECONDS
  steps=$((steps + 1))
  echo
  echo "[$steps] $1"
  shift
  "$@"
  echo "[$steps] ok in $((SECONDS - started))s"
}

# Building every time is deliberate. There used to be mtime comparisons here to
# skip a rebuild, and they were wrong in the one way that matters: the window
# carries its own copy of the release (`bundle.resources` in tauri.conf.json,
# refreshed by `cargo build`), so an Elixir-only change rebuilt
# `_build/desktop/rel` and left the window starting the release it had copied
# hours earlier. What it costs, measured on this machine: the release step is
# ~30-40 s whether or not anything changed (assembling means copying 49 MB,
# 2 713 files — not compiling), and the window step is ~1-3 s when nothing
# changed, because its own cache is left alone.

# `eval` starts no applications, which is all this needs: reading the workspace
# touches a settings file and never the catalogue.
print_workspace() {
  "$sidecar" eval '
    alias ConfluencePhxMirror.Desktop.Settings

    IO.puts("folder:      #{Settings.root()}")
    IO.puts("catalogue:   #{Settings.database()}")
    IO.puts("attachments: #{Settings.blobs()}")
    IO.puts("site:        #{Settings.site() || "(not set)"}")
    IO.puts("account:     #{Settings.email() || "(bearer token)"}")
  '
}

run "building the desktop release (a no-change run only reassembles it)" \
  env MIX_ENV=desktop mix release --overwrite

# No peers to cluster with. A distributed release has a fixed node name, so a
# second launch fails with "the name ... is in use by another Erlang node" and
# dies before it says where it listens — which the window reports as "the
# sidecar stopped before it said where it listens", and which makes `eval` wait
# on a name that is already taken. Everything below runs this release, so it is
# set before the first of them. It is exported after the release build and before
# `cargo build`, which is harmless: the window's build script reruns on
# TAURI_CONFIG and REMOVE_UNUSED_COMMANDS, not on this.
export RELEASE_DISTRIBUTION=none

if [[ "$mode" == where ]]; then
  run "reading the workspace" print_workspace
  exit 0
fi

if [[ "$mode" == browser ]]; then
  echo
  echo "serving the tool in this terminal: it prints its address below, and"
  echo "Ctrl-C stops it. Same routes as the window, one event loop, one stream"
  echo "of output — nothing to wait for, nothing to clean up afterwards."
  echo
  exec "$sidecar" start
fi

# The bundle is the same window with the release carried inside it, so it runs
# where this checkout is not. `open -W` waits for it to quit, which is what
# makes this the last step of a script rather than a process left behind.
if [[ "$mode" == app ]]; then
  run "building the app bundle (a minute warm, six cold — the window is rebuilt in release)" \
    cargo tauri build --bundles app --config "$PWD/$bundle_config"

  echo
  echo "opening the app. Close its window to come back here; Ctrl-C leaves it running."
  echo
  run "the app" open -W "$bundle"
  exit 0
fi

run "building the window (nothing to do when neither the shell nor its config changed)" \
  cargo build --manifest-path src-tauri/Cargo.toml

# The shell is told where the sidecar is, absolutely: it would otherwise resolve
# a relative path against whatever directory it happened to be started in.
export CONFLUENCE_EXPORT_SIDECAR="$sidecar"

# `exec` here would replace the shell with the window, so a hang shows nothing
# and an abort shows nothing either. Run it, say what happened, and pass the
# status on: a launcher that fails silently is worse than one that fails.
echo
echo "opening the window."
echo "  window:  $window"
echo "  sidecar: $sidecar"
echo "The window starts the sidecar, waits for the address it prints, and loads it."
echo "Its output follows. Ctrl-C stops both."
echo

status=0
"$window" || status=$?

echo
echo "the window exited with status $status"
exit "$status"
