#!/usr/bin/env bash
#
# Builds what the desktop workflow publishes, here, so that pushing a tag is not
# the first time anyone finds out what it produces.
#
#   scripts/package.sh             build the app, prove the release inside it
#                                  serves, write the zip the workflow uploads
#   scripts/package.sh --install   …and install that build the way a download
#                                  installs (~/Applications)
#
# The artifact is **the application bundle**: `Confluence Export.app`, zipped. It
# holds the window, the sidecar release with its own Erlang runtime and the icon,
# so a person unzips it, drags it to `/Applications` and double-clicks. A tarball
# of loose binaries is not a macOS application, and the bundle is what
# `scripts/start-desktop.sh --app` already builds and runs.
#
# The release is signed on the way in (`ElixirKit.Release.codesign/1`), because an
# application whose innards are unsigned is not launchable when signed, nor
# notarisation-ready. Without `APPLE_SIGNING_IDENTITY` that signature is ad-hoc:
# enough to make the mechanics real, not enough to satisfy Gatekeeper — that needs
# a Developer ID and notarisation, which are their own piece of work.
#
# `.github/workflows/desktop-release.yml` builds the same bundle with the same
# steps; this script is the local half of that promise, not a second opinion
# about it.
#
# The store the tool uses is the real one, so this touches it: `mix release`
# compiles, and the boot check runs that release against a throwaway `HOME` so a
# tool you have open right now is neither locked nor disturbed.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/bundle.sh
. scripts/lib/bundle.sh

name=confluence_phx_mirror
release="_build/desktop/rel/$name"
sidecar="$PWD/$release/bin/$name"
app="src-tauri/target/release/bundle/macos/Confluence Export.app"
# A separate config, merged only here: `bundle.active` in the main one makes the
# debug window `scripts/start-desktop.sh` opens fail in tauri-build's resource
# phase, and the debug window has no use for a bundle.
bundle_config="$PWD/src-tauri/tauri.bundle.conf.json"
out="_build/desktop/package"
asset="confluence-export-macos.zip"

install_after=no

usage() {
  echo "scripts/package.sh [--install]"
  echo
  echo "  (no flags)   build, check, and write $out/$asset"
  echo "  --install    …then install that build into ~/Applications"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) install_after=yes; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "unknown option: $1"
      usage
      exit 64
      ;;
  esac
done

# One line before and one after each step: a release build is a minute of
# silence otherwise, and when something fails the step that failed is the useful
# thing to know. No redirection — the tools' own output is what explains a
# failure.
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

# A release that builds but does not boot is not a release, and the workflow
# refuses to publish one. This is that same check, run before anything is
# written: it starts the very release the bundle carries as its resource.
#
# It is the one place in this repository that backgrounds a process, and it has
# to be: the release only says where it listens once it is running, and the point
# is to ask it for a page. `HOME` is a scratch directory because the tool's store
# lives under the user's data directory — a check that took the write lock on the
# catalogue somebody has open would be a check nobody dares run.
boot_check() {
  local home log url pid carried
  home=$(mktemp -d)
  log=$(mktemp)

  # The copy inside the bundle, not the one in `_build`: the bundle is what ships,
  # so the bundle is what gets asked.
  carried="$app/Contents/Resources/rel/$name/bin/$name"

  HOME="$home" RELEASE_DISTRIBUTION=none "$carried" start >"$log" 2>&1 &
  pid=$!

  for _ in $(seq 1 60); do
    url=$(sed -n 's/^desktop ui: //p' "$log" | head -1)
    [ -n "$url" ] && break
    sleep 1
  done

  if [ -z "$url" ]; then
    echo "the release never said where it listens:"
    cat "$log"
    kill "$pid" 2>/dev/null || true
    rm -rf "$home" "$log"
    return 1
  fi

  # The address it prints ends with a slash, and `//__tool` is a different path
  # from `/__tool` — one the endpoint answers with a 404.
  url=${url%/}

  # Both halves: the mirror's own health, and the tool's screen, which is the
  # part this build adds. A bundle that serves one and not the other is a
  # download that opens on nothing.
  curl -fsS "$url/health" >/dev/null
  curl -fsS "$url/__tool" >/dev/null
  echo "served $url/health and $url/__tool"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$home" "$log"
}

# The release goes where `resource_dir()` looks for it: inside the bundle's
# `Contents/Resources`, under `rel/`. See `scripts/lib/bundle.sh`.
embed_release() {
  local dest="$app/Contents/Resources/rel/$name"

  bundle_embed_release "$app" "$release" "$name"
  echo "carried $(du -sh "$dest" | cut -f1) into Contents/Resources/rel/$name"
}

assemble() {
  rm -rf "$out"
  mkdir -p "$out"

  # `ditto`, not `zip`: an application bundle is directories, symlinks and
  # extended attributes, and only `ditto -k` (or Finder's own zip) preserves the
  # ones a bundle needs to launch.
  ditto -c -k --keepParent "$app" "$out/$asset"

  # Prove the promise: one file, and the bundle is inside it with **both** halves
  # — the window and the release it starts. Checking only the window is how a
  # 2 MB zip with no `Contents/Resources/rel` passed a workflow gate and shipped
  # an app that could not start anything. The listing is compared, not piped into
  # `grep -q`: that exits at the first match, `unzip` takes the SIGPIPE, and
  # `pipefail` reads 141 as a failure.
  local listing
  listing=$(unzip -l "$out/$asset")
  case "$listing" in
    *"Confluence Export.app/Contents/MacOS/confluence-export"*) ;;
    *)
      echo "the zip does not carry the application bundle:"
      echo "$listing" | head -20
      return 1
      ;;
  esac

  case "$listing" in
    *"Confluence Export.app/Contents/Resources/rel/$name/bin/$name"*) ;;
    *)
      echo "the zip carries a window with no release behind it:"
      echo "$listing" | grep "Contents/Resources" | head -20
      return 1
      ;;
  esac

  ls -lh "$out/$asset"
}

# A release ships whatever `priv/static` holds and never builds it, so these are
# the steps that decide what the window looks like. They are the four that
# `scripts/start-desktop.sh` runs, for the same reason: a skipped one is a
# console full of "unknown hook found" and a menu that does not open.
run "checking the asset toolchain (installs it once, then finds it)" \
  env MIX_ENV=desktop mix assets.install --if-missing

# The JavaScript the bundle imports is npm's — `js/code_highlight.js` pulls
# highlight.js' grammars — and `mix esbuild` only bundles it. `mix
# assets.install` above fetches the esbuild and tailwind *binaries*, not
# `assets/node_modules`, so a clone that has never run `npm ci` fails at the
# first bundle with "Could not resolve highlight.js/lib/languages/diff". The
# release workflow did exactly that on every run.
if [[ ! -d assets/node_modules ]]; then
  run "installing the assets' npm packages (a fresh clone has none)" \
    env npm --prefix assets ci --no-audit --no-fund
fi

run "building the stylesheet" \
  env MIX_ENV=desktop mix tailwind confluence_phx_mirror --minify

run "building the scripts" \
  env MIX_ENV=desktop mix esbuild confluence_phx_mirror --minify

run "building the scripts the API docs page loads" \
  env MIX_ENV=desktop mix esbuild confluence_phx_mirror_swagger --minify

run "digesting the assets (the manifest the screens link through)" \
  env MIX_ENV=desktop mix phx.digest

run "fetching the desktop dependencies (a fresh clone has none)" \
  env MIX_ENV=desktop mix deps.get

run "building the sidecar release, signed (ad-hoc without a certificate)" \
  env MIX_ENV=desktop CONFLUENCE_SIGN_RELEASE=1 mix release --overwrite

# The bundle is built after the release on purpose: the release has to exist
# before it can go inside, or the app would carry the previous build — the trap
# that made a window start code from hours earlier.
run "building the application shell" \
  cargo tauri build --bundles app --config "$bundle_config"

# The release goes in here rather than through `bundle.resources`. Tauri's own
# copy of this tree (2 700 files, addressed across a `..` in the config) fails in
# its resource phase with "Permission denied (os error 13)" on this toolchain,
# and one `ditto` puts it exactly where the shell looks it up:
# `resource_dir()/rel/confluence_phx_mirror`, which is
# `Contents/Resources/rel/confluence_phx_mirror` in a macOS app.
run "carrying the release into the bundle" embed_release

run "booting the release the bundle carries and asking it to serve" boot_check

run "assembling the artifact" assemble

if [[ $install_after == yes ]]; then
  run "installing that build the way a download installs" \
    env CONFLUENCE_EXPORT_BASE_URL="file://$PWD/$out" ./install-desktop.sh
fi

echo
echo "artifact: $out/$asset"
echo "uploaded by the workflow as: confluence-export-macos"
[[ $install_after == yes ]] || echo "to install it: scripts/package.sh --install"
