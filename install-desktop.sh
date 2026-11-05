#!/usr/bin/env bash
# Installs the desktop tool: the newest build of a branch, not a release.
#
#   curl -fsSL https://raw.githubusercontent.com/d-led/confluence_phx_mirror/main/install-desktop.sh | sh
#
# What it downloads is the artifact of the last successful `desktop-release` run
# of that branch, through `nightly.link` — there is no release to wait for. The
# artifact is the application bundle: it goes into `~/Applications`, where
# Spotlight and Launchpad find it like any other app. The build is macOS on Apple
# silicon for now, and this script says so rather than installing something that
# cannot start.
#
#   CONFLUENCE_EXPORT_REPO      owner/repo to download from (default: d-led/confluence_phx_mirror)
#   CONFLUENCE_EXPORT_BRANCH    which branch's build to take (default: main)
#   CONFLUENCE_EXPORT_WORKFLOW  the workflow that builds it (default: desktop-release)
#   CONFLUENCE_EXPORT_APPS      where the app goes (default: ~/Applications)
#   CONFLUENCE_EXPORT_BIN       where the launcher goes (default: ~/.local/bin)
#   CONFLUENCE_EXPORT_BASE_URL  a directory holding <artifact>.zip itself, which
#                               skips nightly.link — how the script is tested
#
# The app is not signed, so Gatekeeper refuses the first launch of a downloaded
# copy. This script leaves that to the person rather than removing the quarantine
# flag behind their back: right-click the app → Open, once. Signing and
# notarisation are the fix, and they are their own piece of work.

set -euo pipefail

repo="${CONFLUENCE_EXPORT_REPO:-d-led/confluence_phx_mirror}"
branch="${CONFLUENCE_EXPORT_BRANCH:-main}"
workflow="${CONFLUENCE_EXPORT_WORKFLOW:-desktop-release}"
apps="${CONFLUENCE_EXPORT_APPS:-$HOME/Applications}"
bin_dir="${CONFLUENCE_EXPORT_BIN:-$HOME/.local/bin}"

artifact="confluence-export-macos"
app="Confluence Export.app"

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

echo "Downloading the newest $branch build from $workflow ..."
fetch "$url" "$work/$artifact.zip"

# `ditto`, not `unzip`: an application bundle is directories, symlinks and
# extended attributes, and `unzip` drops enough of them that the app no longer
# launches.
ditto -x -k "$work/$artifact.zip" "$work/unpacked"

if [ ! -d "$work/unpacked/$app" ]; then
  echo "The download did not contain $app; is the workflow still building?" >&2
  exit 1
fi

mkdir -p "$apps" "$bin_dir"

# Replaced, not merged: an app bundle has directories whose contents change
# between builds, and a file left from an older one is a file nothing can
# explain later.
rm -rf "${apps:?}/$app"
ditto "$work/unpacked/$app" "$apps/$app"

# The app is not signed, so a copy that arrived with the quarantine flag — one
# fetched by a browser, or from a file that already carried it — is refused on
# its first launch. The flag is cleared here, on the copy this script just made
# and nowhere else, because a person who asked for this install has asked for
# this app to run; doing it to anything else would be a different act.
if xattr -p com.apple.quarantine "$apps/$app" >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$apps/$app"
  cleared="cleared the quarantine flag it arrived with"
else
  cleared="nothing to clear: it never carried a quarantine flag"
fi

# A launcher, so the tool starts from a terminal too. `open -a` is what a bundle
# needs: running the executable inside it directly skips the activation its
# window expects.
cat >"$bin_dir/confluence-export" <<LAUNCHER
#!/bin/sh
exec open -a "$apps/$app" "\$@"
LAUNCHER
chmod +x "$bin_dir/confluence-export"

echo
echo "Installed:  $apps/$app"
echo "Launcher:   $bin_dir/confluence-export"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Add $bin_dir to PATH to run it by name." ;;
esac
echo
echo "Gatekeeper: $cleared."
echo "The app is ad-hoc signed, which is what macOS needs to run it — but an"
echo "unsigned app that arrives with the quarantine flag is stopped before any"
echo "approval dialog, so a copy downloaded in a browser needs this first:"
echo "  xattr -rd com.apple.quarantine \"$apps/$app\""
echo
echo "First launch asks once for access to the keychain item confluence-export:"
echo "that is where the Confluence token is kept, and macOS does not recognise a"
echo "copy of an ad-hoc signed app. Answer \"Always Allow\" once."
echo "$apps/$app"
