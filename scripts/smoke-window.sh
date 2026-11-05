#!/usr/bin/env bash
#
# The window, opened the way a person opens it.
#
# Everything else that checks a desktop build asks the *server* inside it a
# question: `scripts/package.sh` boots the release and fetches `/health`, and the
# release workflow boots the unpacked artifact and fetches `/__tool`. Both are
# worth doing, and both passed while the window itself was broken — it judged its
# own splash page a foreign link, opened a console and a browser instead of the
# tool, and every one of those checks stayed green.
#
# So this starts the executable that ships and waits for it to say what it **sees**:
# the tool's pages report the document they built — heading, the boxes a person
# types into, the word on the button — and only a window builds one (see
# `ConfluencePhxMirror.Desktop.Web.Paint`). A fresh workspace lands on the setup
# form, so that is the screen this checks for: a path alone would pass a window
# showing nothing anybody could fill in.#
#
#   scripts/smoke-window.sh [--window PATH] [--port N] [--seconds N]
#
# It asserts structure, not pixels: a screenshot of a person's desktop is not
# something a test should take, and a runner with no graphics session has no
# screen to photograph anyway. The first picture this repository takes of a
# window will be a webview screenshot over CDP on Windows, where WebView2 exposes
# one — not a photograph of the machine.
#
# `HOME` is a scratch directory, so this never opens the workspace the person
# running it is using: a smoke test that took the write lock on a real catalogue
# is a test nobody dares run. On Windows the workspace sits in a fixed folder no
# environment variable moves, so there this wants no other copy of the tool open.
#
# A machine with no display (a Linux runner) gets Xvfb when it is installed. A
# window that never opens is a real failure and says so; a window that opens on
# nothing — the shape that shipped — is told apart from it by asking `/health`
# first and the paint report second.
set -uo pipefail

cd "$(dirname "$0")/.."

platform() {
  case $(uname -s) in
    Darwin) echo macos ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *) echo linux ;;
  esac
}

platform=$(platform)

case $platform in
  macos) default_window="src-tauri/target/release/bundle/macos/Confluence Export.app/Contents/MacOS/confluence-export" ;;
  windows) default_window="_build/desktop/package/confluence-export-windows/confluence-export.exe" ;;
  *) default_window="_build/desktop/package/confluence-export-linux/confluence-export" ;;
esac

window=$default_window
port=43998
seconds=60

while [[ $# -gt 0 ]]; do
  case $1 in
    --window) window=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    --seconds) seconds=$2; shift 2 ;;
    -h | --help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -x $window ]]; then
  echo "no window at $window" >&2
  echo "(build it with scripts/package.sh, or point --window at one)" >&2
  exit 1
fi

# The port has to be free, because the tool steps around a taken one: a launch
# that answered on some other number would leave this script polling nothing.
if curl -s -m 1 -o /dev/null "http://127.0.0.1:$port/"; then
  echo "something already answers on 127.0.0.1:$port — pass --port with a free one" >&2
  exit 1
fi

home=$(mktemp -d)
log=$(mktemp)

runner=()
if [[ $platform == linux && -z ${DISPLAY:-} ]] && command -v xvfb-run >/dev/null; then
  runner=(xvfb-run -a --server-args="-screen 0 1280x1024x24")
fi

# `WEBKIT_DISABLE_COMPOSITING_MODE` and `NO_AT_BRIDGE` are for the webview on a
# machine with no graphics hardware and no accessibility bus, which is what a
# container is: without them WebKitGTK can fail to draw anything at all, and the
# report this script waits for would never come.
#
# One list rather than prefixing the launch line with `env …`: the display wrapper
# is often empty, and `set -u` with an empty array is an error on the bash that
# ships with macOS.
launch=(
  env HOME="$home" CONFLUENCE_EXPORT_PORT="$port"
  WEBKIT_DISABLE_COMPOSITING_MODE=1 NO_AT_BRIDGE=1
)
[[ ${#runner[@]} -gt 0 ]] && launch+=("${runner[@]}")
launch+=("$window")

"${launch[@]}" >"$log" 2>&1 &
pid=$!

stop() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$home" "$log"
}

fail() {
  echo "$1" >&2
  echo "--- what the window said:" >&2
  tail -25 "$log" >&2
  stop
  exit 1
}

# The server first: a window whose server never started is a different fault from
# a window whose server is fine and whose page never painted.
up=
for _ in $(seq 1 30); do
  if curl -fsS -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    up=yes
    break
  fi
  sleep 1
done

[[ -n $up ]] || fail "the window never started its server on 127.0.0.1:$port"

painted=
for _ in $(seq 1 "$seconds"); do
  if painted=$(curl -fsS -m 2 "http://127.0.0.1:$port/__tool/painted" 2>/dev/null); then
    break
  fi
  painted=
  sleep 1
done

if [[ -z $painted ]]; then
  fail "the server is up but no window drew a screen — it opened on nothing"
fi

printf '%s\n' "$painted"

heading=$(printf '%s\n' "$painted" | sed -n 's/^heading: //p')
fields=$(printf '%s\n' "$painted" | sed -n 's/^fields: //p')

[[ -n $heading ]] || fail "the window drew a screen with no heading on it"

# The setup form, box by box. A page that loads without them is not the screen
# this build promises a first launch: it is a window showing something inert.
for box in site email secret root; do
  case ",$fields," in
    *",$box,"*) ;;
    *) fail "the window drew a screen but its setup form has no '$box' box (it saw: ${fields:-none})" ;;
  esac
done

echo "the window shows \"$heading\" with the setup form's boxes: $fields"

stop
exit 0
