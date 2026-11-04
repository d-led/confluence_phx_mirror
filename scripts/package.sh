#!/usr/bin/env bash
#
# Builds what the desktop workflow publishes, here, so that pushing a tag is not
# the first time anyone finds out what it produces.
#
#   scripts/package.sh             build both halves, prove the release serves,
#                                  write the artifact the workflow uploads
#   scripts/package.sh --install   …and then install that build the way the
#                                  published one installs (~/.local/share)
#
# The artifact is one tarball, `confluence-export-macos.tar.gz`, holding the
# window, the sidecar release with its own Erlang runtime, and the `start`
# launcher that ties them together. `.github/workflows/desktop-release.yml`
# builds the same tree with the same steps; this script is the local half of
# that promise, not a second opinion about it.

set -euo pipefail

cd "$(dirname "$0")/.."

name=confluence_phx_mirror
release="_build/desktop/rel/$name"
sidecar="$PWD/$release/bin/$name"
window="src-tauri/target/release/confluence-export"
out="_build/desktop/package"
asset="confluence-export-macos.tar.gz"

install_after=no

usage() {
  echo "scripts/package.sh [--install]"
  echo
  echo "  (no flags)   build, check, and write $out/$asset"
  echo "  --install    …then install that build into ~/.local/share/confluence-export"
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
# written.
#
# It is the one place in this repository that backgrounds a process, and it has
# to be: the release only says where it listens once it is running, and the point
# is to ask it for a page. `HOME` is a scratch directory because the tool's store
# lives under the user's data directory — a check that took the write lock on the
# catalogue somebody has open would be a check nobody dares run.
boot_check() {
  local home log url pid
  home=$(mktemp -d)
  log=$(mktemp)

  HOME="$home" RELEASE_DISTRIBUTION=none "$sidecar" start >"$log" 2>&1 &
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
  # part this build adds. A release that serves one and not the other is a
  # download that opens on nothing.
  curl -fsS "$url/health" >/dev/null
  curl -fsS "$url/__tool" >/dev/null
  echo "served $url/health and $url/__tool"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$home" "$log"
}

# The tree the workflow tars: the release, the window, and the launcher that
# points one at the other.
assemble() {
  rm -rf "$out"
  mkdir -p "$out/tree"
  cp -R "_build/desktop/rel/$name" "$out/tree/$name"
  cp "$window" "$out/tree/confluence-export"

  cat >"$out/tree/start" <<'SCRIPT'
#!/bin/sh
# Starts the tool. The window runs the sidecar beside it; setting the path here is
# what ties the two downloaded pieces together until there is an application
# bundle to do it.
here=$(cd "$(dirname "$0")" && pwd)
export CONFLUENCE_EXPORT_SIDECAR="$here/confluence_phx_mirror/bin/confluence_phx_mirror"
exec "$here/confluence-export" "$@"
SCRIPT
  chmod +x "$out/tree/start"

  # `COPYFILE_DISABLE` keeps macOS's `tar` from writing the `._` files that
  # otherwise land in an archive made from a checkout.
  COPYFILE_DISABLE=1 tar -czf "$out/$asset" -C "$out/tree" .
  rm -rf "$out/tree"

  # The zip is what `nightly.link` hands out; making it here is what lets
  # `--install` exercise the published path without publishing anything.
  (cd "$out" && zip -q "${asset%.tar.gz}.zip" "$asset")

  ls -lh "$out/$asset"
}

# A release ships whatever `priv/static` holds and never builds it, so these are
# the steps that decide what the window looks like. They are the four that
# `scripts/start-desktop.sh` runs, for the same reason: a skipped one is a
# console full of "unknown hook found" and a menu that does not open.
run "checking the asset toolchain (installs it once, then finds it)" \
  env MIX_ENV=desktop mix assets.install --if-missing

run "building the stylesheet" \
  env MIX_ENV=desktop mix tailwind confluence_phx_mirror --minify

run "building the scripts" \
  env MIX_ENV=desktop mix esbuild confluence_phx_mirror --minify

run "building the scripts the API docs page loads" \
  env MIX_ENV=desktop mix esbuild confluence_phx_mirror_swagger --minify

run "digesting the assets (the manifest the screens link through)" \
  env MIX_ENV=desktop mix phx.digest

run "building the sidecar release" \
  env MIX_ENV=desktop mix release --overwrite

run "building the window (release profile)" \
  cargo build --release --manifest-path src-tauri/Cargo.toml

run "booting the release and asking it to serve" boot_check

run "assembling the artifact" assemble

if [[ $install_after == yes ]]; then
  run "installing that build the way the published one installs" \
    env CONFLUENCE_EXPORT_BASE_URL="file://$PWD/$out" ./install-desktop.sh
fi

echo
echo "artifact: $out/$asset"
echo "uploaded by the workflow as: confluence-export-macos"
[[ $install_after == yes ]] || echo "to install it: scripts/package.sh --install"
