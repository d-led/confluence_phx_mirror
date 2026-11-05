#!/bin/sh
# Installs the desktop tool: the newest build of a branch, not a release.
#
#   curl -fsSL https://raw.githubusercontent.com/d-led/confluence_phx_mirror/main/install-desktop.sh | sh
#
# What it downloads is the artifact of the last successful `desktop-release` run
# of that branch, through `nightly.link` — there is no release to wait for. That
# artifact arrives inside a zip `nightly.link` makes, and on macOS and Linux the
# artifact is an archive itself, so what the download holds is one archive inside
# another; this unpacks the outer one and, if that is what it is, the inner one
# too. What it does with it then depends on the platform, because what a person
# installs does:
#
#   macOS   `Confluence Export.app` into `~/Applications`, where Spotlight and
#           Launchpad find it like any other app
#   Linux   the window and the release it starts into
#           `~/.local/share/confluence-export`, with a launcher in `~/.local/bin`
#   Windows not this file: `install-desktop.ps1` is the Windows form of the same
#           line, and this one names it when it is run there
#
# The macOS build is Apple silicon and the Linux one is x86_64; each says so
# rather than installing something that cannot start.
#
#   CONFLUENCE_EXPORT_REPO      owner/repo to download from (default: d-led/confluence_phx_mirror)
#   CONFLUENCE_EXPORT_BRANCH    which branch's build to take (default: main)
#   CONFLUENCE_EXPORT_WORKFLOW  the workflow that builds it (default: desktop-release)
#   CONFLUENCE_EXPORT_APPS      macOS: where the app goes (default: ~/Applications)
#   CONFLUENCE_EXPORT_DIR       Linux: where the tool is kept (default:
#                               ${XDG_DATA_HOME:-~/.local/share}/confluence-export/app)
#   CONFLUENCE_EXPORT_BIN       where the launcher goes (default: ~/.local/bin)
#   CONFLUENCE_EXPORT_BASE_URL  a directory or URL holding <artifact>.zip itself,
#                               which skips nightly.link — how the script is tested
#
# It is `sh`, not bash: the line is short enough to type and every shell that
# answers to `sh` should run it. It also reads nothing from standard input, and
# says so with `</dev/null` wherever a command is started: a script that arrives
# on standard input (`curl … | sh`) and then reads it eats its own remaining text
# and runs that, which is how a remote install line ends up running for ever.
#
# The app is not signed or notarised — macOS stops a downloaded copy before it
# offers to run it, Windows shows a SmartScreen prompt. This script clears the
# quarantine flag on the copy it just made and on nothing else, because a person
# who asked for this install has asked for this app to run. Signing and
# notarisation are the fix, and they are their own piece of work.

set -eu

repo="${CONFLUENCE_EXPORT_REPO:-d-led/confluence_phx_mirror}"
branch="${CONFLUENCE_EXPORT_BRANCH:-main}"
workflow="${CONFLUENCE_EXPORT_WORKFLOW:-desktop-release}"
bin_dir="${CONFLUENCE_EXPORT_BIN:-$HOME/.local/bin}"

os=$(uname -s)
machine=$(uname -m)

case "$os" in
  Darwin) platform=macos ;;
  Linux) platform=linux ;;
  MINGW* | MSYS* | CYGWIN*)
    echo "On Windows the install line is the PowerShell one:" >&2
    echo "  powershell -ExecutionPolicy Bypass -Command \"irm https://raw.githubusercontent.com/$repo/$branch/install-desktop.ps1 | iex\"" >&2
    exit 1
    ;;
  *)
    echo "This installs on macOS and Linux; $os is neither. Windows has install-desktop.ps1." >&2
    exit 1
    ;;
esac

artifact=""
case "$platform:$machine" in
  macos:arm64) artifact="confluence-export-macos" ;;
  macos:*)
    echo "The macOS build is Apple silicon (arm64); this machine is $machine." >&2
    exit 1
    ;;
  linux:x86_64 | linux:amd64) artifact="confluence-export-linux" ;;
  linux:*)
    echo "The Linux build is x86_64; this machine is $machine." >&2
    exit 1
    ;;
esac

# Where the build comes from: `nightly.link`, unless somebody names a directory
# (or an address) holding the same zip — which is how this is tried without a
# network round trip, and what `scripts/package.sh --install` uses.
base="${CONFLUENCE_EXPORT_BASE_URL:-}"
case "$base" in
  "") url="https://nightly.link/$repo/workflows/$workflow/$branch/$artifact.zip" ;;
  http://* | https://* | file://*) url="$base/$artifact.zip" ;;
  *) url="file://$(cd "$base" && pwd)/$artifact.zip" ;;
esac

# A download with a deadline and three attempts, never a loop: a build that is
# not there yet is the normal answer while a platform's job is red, and it has to
# arrive as a sentence instead of a spinner. `</dev/null` because this script can
# itself arrive on standard input.
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar --connect-timeout 20 --max-time 900 \
      --retry 2 --retry-delay 2 -o "$2" "$1" </dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q --show-progress --tries=3 --timeout=300 -O "$2" "$1" </dev/null
  else
    echo "This needs curl or wget to download with; install one of them and run it again." >&2
    exit 1
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

echo "Downloading the newest $branch build of $workflow ..."
if ! fetch "$url" "$work/$artifact.zip"; then
  echo
  echo "Nothing came from $url — so nothing was installed." >&2
  echo "Whether that build exists is on the workflow page:" >&2
  echo "  https://github.com/$repo/actions/workflows/$workflow.yml" >&2
  exit 1
fi

case "$platform" in
  macos)
    # `ditto`, not `unzip`: an application bundle is directories, symlinks and
    # extended attributes, and `unzip` drops enough of them that the app no
    # longer launches.
    ditto -x -k "$work/$artifact.zip" "$work/unpacked" </dev/null

    # Two layers, and this is the line that was wrong: `nightly.link` serves the
    # artifact inside a zip of its own, and the macOS artifact *is* a zip — what
    # arrives is a zip holding `confluence-export-macos.zip`, not the app. Unpack
    # that one too. Exactly once: an installer that keeps unpacking whatever it
    # finds inside is an installer that never finishes.
    if [ -f "$work/unpacked/$artifact.zip" ]; then
      ditto -x -k "$work/unpacked/$artifact.zip" "$work/app" </dev/null
      bundle="$work/app/Confluence Export.app"
    else
      bundle="$work/unpacked/Confluence Export.app"
    fi
    ;;
  linux)
    # Two layers: `nightly.link` serves the artifact as the zip GitHub stored,
    # and the Linux artifact is a tarball. `unzip` is what most distributions
    # have; python3 reads the same file where it is not installed.
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "$work/$artifact.zip" -d "$work/unpacked" </dev/null
    elif command -v python3 >/dev/null 2>&1; then
      python3 -m zipfile -e "$work/$artifact.zip" "$work/unpacked" </dev/null
    else
      echo "Unpacking needs unzip or python3; install one of them and run this again." >&2
      exit 1
    fi

    tar -xzf "$work/unpacked/$artifact.tar.gz" -C "$work" </dev/null
    bundle="$work/$artifact"
    ;;
esac

if [ ! -e "$bundle" ]; then
  echo "The download did not contain what this installs; is the workflow still building?" >&2
  exit 1
fi

case "$platform" in
  macos)
    apps="${CONFLUENCE_EXPORT_APPS:-$HOME/Applications}"
    case "$apps" in
      "" | "/")
        echo "CONFLUENCE_EXPORT_APPS is '$apps', which is not a folder to install into." >&2
        exit 1
        ;;
    esac

    mkdir -p "$apps"
    installed="$apps/Confluence Export.app"

    # Replaced, not merged: an app bundle has directories whose contents change
    # between builds, and a file left from an older one is a file nothing can
    # explain later.
    rm -rf "$installed"
    ditto "$bundle" "$installed"
    ;;
  linux)
    dir="${CONFLUENCE_EXPORT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/confluence-export/app}"
    case "$dir" in
      "" | "/")
        echo "CONFLUENCE_EXPORT_DIR is '$dir', which is not a folder to install into." >&2
        exit 1
        ;;
    esac

    installed="$dir"
    rm -rf "$installed"
    mkdir -p "$installed"

    # `cp -a`, so the release keeps the permissions it was built with: the
    # launcher it carries has to stay executable.
    cp -a "$bundle/." "$installed/"
    ;;
esac

mkdir -p "$bin_dir"

# A launcher, so the tool starts from a terminal too. On macOS that is `open -a`,
# which is what a bundle needs — running the executable inside it directly skips
# the activation its window expects. On Linux the window is the program.
case "$platform" in
  macos)
    cat >"$bin_dir/confluence-export" <<LAUNCHER
#!/bin/sh
exec open -a "$installed" "\$@"
LAUNCHER
    ;;
  linux)
    cat >"$bin_dir/confluence-export" <<LAUNCHER
#!/bin/sh
exec "$installed/confluence-export" "\$@"
LAUNCHER
    ;;
esac
chmod +x "$bin_dir/confluence-export"

# macOS only, and only on the copy this script just made: a flag that arrived
# with the download is refused before any approval dialog is offered, and a
# person who asked for this install has asked for this app to run.
cleared="not applicable on this platform"
if [ "$platform" = macos ]; then
  if xattr -p com.apple.quarantine "$installed" >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$installed"
    cleared="cleared the quarantine flag it arrived with"
  else
    cleared="nothing to clear: it never carried a quarantine flag"
  fi
fi

# What the Linux window draws with, asked rather than assumed: a missing library
# is a window that closes before it opens, and the message should say which one.
missing=""
if [ "$platform" = linux ] && command -v ldconfig >/dev/null 2>&1; then
  for lib in libgtk-3.so.0 libwebkit2gtk-4.1.so.0; do
    ldconfig -p 2>/dev/null | grep -q "$lib" || missing="$missing $lib"
  done
fi

echo
echo "Installed:  $installed"
echo "Launcher:   $bin_dir/confluence-export"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Add $bin_dir to PATH to run it by name." ;;
esac
echo

case "$platform" in
  macos)
    echo "Gatekeeper: $cleared."
    echo "The app is ad-hoc signed, which is what macOS needs to run it — but an"
    echo "unsigned app that arrives with the quarantine flag is stopped before any"
    echo "approval dialog, so a copy downloaded in a browser needs this first:"
    echo "  xattr -rd com.apple.quarantine \"$installed\""
    echo
    echo "First launch asks once for access to the keychain item confluence-export:"
    echo "that is where the Confluence token is kept, and macOS does not recognise a"
    echo "copy of an ad-hoc signed app. Answer \"Always Allow\" once."
    ;;
  linux)
    if [ -n "$missing" ]; then
      echo "The window draws with GTK 3 and WebKitGTK 4.1, and this machine is missing:"
      for lib in $missing; do echo "  $lib"; done
      echo "On Debian and Ubuntu:"
      echo "  sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0 librsvg2-2 libayatana-appindicator3-1"
    else
      echo "GTK 3 and WebKitGTK 4.1 are here, which is what the window draws with."
    fi
    echo
    echo "What it mirrors is kept in ${XDG_DATA_HOME:-$HOME/.local/share}/confluence-export."
    ;;
esac

echo "$installed"
