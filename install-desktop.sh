#!/usr/bin/env bash
# Installs the desktop tool: the newest build of a branch, not a release.
#
#   curl -fsSL https://raw.githubusercontent.com/d-led/confluence_phx_mirror/main/install-desktop.sh | sh
#
# What it downloads is the artifact of the last successful `desktop-release` run
# of that branch, through `nightly.link` — there is no release to wait for. The
# build is macOS (Apple silicon) only for now, and this script says so rather
# than installing something that cannot start.
#
#   CONFLUENCE_EXPORT_REPO      owner/repo to download from (default: d-led/confluence_phx_mirror)
#   CONFLUENCE_EXPORT_BRANCH    which branch's build to take (default: main)
#   CONFLUENCE_EXPORT_WORKFLOW  the workflow that builds it (default: desktop-release)
#   CONFLUENCE_EXPORT_HOME      where the tool lives (default: ~/.local/share/confluence-export)
#   CONFLUENCE_EXPORT_BIN       where the launcher goes (default: ~/.local/bin)
#   CONFLUENCE_EXPORT_BASE_URL  a directory holding <artifact>.zip itself, which
#                               skips nightly.link — how the script is tested

set -euo pipefail

repo="${CONFLUENCE_EXPORT_REPO:-d-led/confluence_phx_mirror}"
branch="${CONFLUENCE_EXPORT_BRANCH:-main}"
workflow="${CONFLUENCE_EXPORT_WORKFLOW:-desktop-release}"
home="${CONFLUENCE_EXPORT_HOME:-$HOME/.local/share/confluence-export}"
bin_dir="${CONFLUENCE_EXPORT_BIN:-$HOME/.local/bin}"

artifact="confluence-export-macos"

case "$(uname -s)" in
  Darwin) ;;
  *)
    echo "The desktop tool is built for macOS so far; $(uname -s) is not published." >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64) ;;
  *)
    echo "The published build is Apple silicon (arm64); this machine is $(uname -m)." >&2
    exit 1
    ;;
esac

url="${CONFLUENCE_EXPORT_BASE_URL:-https://nightly.link/$repo/workflows/$workflow/$branch}/$artifact.zip"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --show-progress "$1" -O "$2"
  else
    echo "Install curl or wget first." >&2
    exit 1
  fi
}

unzip_to() {
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$1" -d "$2"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e "$1" "$2"
  else
    echo "Install unzip (or python3) first: the download arrives zipped." >&2
    exit 1
  fi
}

echo "Downloading the newest $branch build from $workflow ..."
fetch "$url" "$work/$artifact.zip"
unzip_to "$work/$artifact.zip" "$work/unpacked"

# The artifact is a tarball inside the zip: the zip an artifact arrives in does
# not carry file modes, and the release's `bin/*` and the launcher have to stay
# executable.
tarball="$(find "$work/unpacked" -maxdepth 1 -name '*.tar.gz' | head -1)"
if [ -z "$tarball" ]; then
  echo "The download did not contain a tarball; is the workflow still building?" >&2
  exit 1
fi

mkdir -p "$home" "$bin_dir"
# The tree is replaced, not merged: a release has directories whose contents
# change between builds, and a leftover file from an older one would be found by
# the runtime and could not be explained by anything.
rm -rf "${home:?}"/*
tar -xzf "$tarball" -C "$home"
chmod +x "$home/start" "$home/confluence-export" 2>/dev/null || true

# A launcher, not a symlink. `start` finds the window beside itself from its own
# path, so a symlink named `confluence-export` pointing at `start` would make
# `start` find the symlink and exec itself, for ever; the absolute path here has
# no such ambiguity.
cat >"$bin_dir/confluence-export" <<LAUNCHER
#!/bin/sh
exec "$home/start" "\$@"
LAUNCHER
chmod +x "$bin_dir/confluence-export"

echo
echo "Installed into $home"
echo "Launcher:  $bin_dir/confluence-export"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Add $bin_dir to PATH to run it by name." ;;
esac
echo "$bin_dir/confluence-export"
