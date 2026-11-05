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
#   scripts/smoke-window.sh [--window PATH] [--port N] [--seconds N] [--up-seconds N]
#
# `--up-seconds` is the time the release gets to say it is listening. Sixty is
# the same budget `scripts/package.sh` gives it, and it is not padding: a cold
# Erlang boot on a loaded Windows runner is tens of seconds, and a shorter
# deadline reports "the window never started" about a window that was fine.
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
up_seconds=60
seconds=60

while [[ $# -gt 0 ]]; do
  case $1 in
    --window) window=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    --up-seconds) up_seconds=$2; shift 2 ;;
    --seconds) seconds=$2; shift 2 ;;
    -h | --help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Where the tool keeps its own log, per platform. On Windows that is a fixed
# folder no environment variable moves, so the scratch `HOME` above does not
# apply there — which is also why this check wants no other copy of the tool
# open on Windows.
if [[ $platform == windows ]]; then
  workspace="$(cygpath -u "${LOCALAPPDATA:-$HOME/AppData/Local}")/confluence-export"
elif [[ $platform == macos ]]; then
  workspace="$home/Library/Application Support/confluence-export"
else
  workspace="$home/.local/share/confluence-export"
fi
tool_log="$workspace/logs/desktop.log"

# The window keeps its own log beside its own identity rather than in the tool's
# workspace, and Tauri names that directory after the bundle identifier.
BUNDLE_ID="dev.confluence-export.desktop"
if [[ $platform == windows ]]; then
  app_data=$(cygpath -u "${LOCALAPPDATA:-$HOME/AppData/Local}")
else
  app_data="$home"
fi

"${launch[@]}" >"$log" 2>&1 &
pid=$!

stop() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$home" "$log"
}

fail() {
  echo "$1" >&2

  # Everything, not a tail. A pipe that has been quietly losing the interesting
  # line is the reason this script exists, and a log nobody prints is a log
  # nobody reads: a CI run whose output is one sentence sends somebody to a
  # Windows machine to find out what happened.
  echo "--- what the window said ($log):" >&2
  cat "$log" >&2

  if [[ -f $tool_log ]]; then
    # The path as well as the contents: the log is appended across launches, so
    # the same file can hold lines from the packaging boot check that ran a
    # moment earlier — and a reader who does not know the path cannot tell whose
    # lines they are looking at.
    echo "--- what the tool logged ($tool_log):" >&2
    cat "$tool_log" >&2
  else
    echo "--- the tool wrote no log at $tool_log" >&2
  fi

  # The window's *own* log: the release's output as the window read it, which is
  # where a launch that never became a server leaves its reason. Tauri names the
  # directory after the bundle identifier, so the few shapes it can have are
  # asked for by name rather than searched for across an entire profile.
  local window_log
  for window_log in \
    "$app_data/Library/Logs/$BUNDLE_ID/sidecar.log" \
    "$app_data/.local/share/$BUNDLE_ID/logs/sidecar.log" \
    "$app_data/$BUNDLE_ID/logs/sidecar.log"; do
    if [[ -f $window_log ]]; then
      echo "--- the window's own log ($window_log):" >&2
      cat "$window_log" >&2
    fi
  done

  stop
  exit 1
}

# The server first: a window whose server never started is a different fault from
# a window whose server is fine and whose page never painted. A window that is
# still running and a window that has died are different again, and the second
# one has an exit code worth printing.
up=
for i in $(seq 1 "$up_seconds"); do
  if curl -fsS -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    up=yes
    break
  fi

  [[ $((i % 10)) -eq 0 ]] && echo "waiting for the server on 127.0.0.1:$port (${i}s)"
  sleep 1
done

if [[ -z $up ]]; then
  if kill -0 "$pid" 2>/dev/null; then
    fail "the window is running but never served 127.0.0.1:$port within ${up_seconds}s"
  fi

  wait "$pid" 2>/dev/null
  code=$?
  fail "the window exited before it started a server (exit $code)"
fi

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
