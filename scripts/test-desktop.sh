#!/usr/bin/env bash
#
# The tool's own suite: `MIX_ENV=desktop`, its own test path, its own HOME.
#
# Three things this does that `mix test` alone does not:
#
#   * `MIX_ENV=desktop`, because `lib_desktop/` is compiled only there. The
#     server's suite cannot see a module the tool owns.
#   * `HOME` is a scratch directory. The tool keeps its catalogue under the user's
#     data directory, and a suite that read or wrote the real one would fight the
#     copy somebody has open — the same class of failure as two suites sharing a
#     test database.
#   * `--no-start`: these tests are about logic that does not need the whole tree
#     (a router's headers, a port decision, where the settings file is read from).
#     Starting the release's supervision to ask those questions would make every
#     test depend on the keychain, the listener and the migrations.
#
#   scripts/test-desktop.sh                      the suite
#   scripts/test-desktop.sh test_desktop/desktop/web/server_test.exs   one file
#   scripts/test-desktop.sh --only dispatcher    ExUnit filters, as usual
#
# `scripts/package.sh` proves the release boots; this proves the code behind it
# says what it means. Neither replaces the other.

set -euo pipefail

cd "$(dirname "$0")/.."

# `HOME` is what the *app* reads — its data directory, and on macOS the keychain
# as the login user. `MIX_HOME` and `HEX_HOME` are the *toolchain's*, and moving
# them would make Mix ask to install Hex again on every run (a prompt inside a
# script is a hang). So the app gets a scratch home and Mix keeps the real one.
real_home=$HOME
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

# A port that is free right now, so the tool's own preference (43_100) cannot
# collide with a copy someone has open — `Desktop.Web.Server.choose_port/0`
# refuses to start when the port is answered by another copy of the app, and a
# test run is not a good moment to be told that in a paragraph.
free_port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)

HOME="$home" \
  MIX_HOME="${MIX_HOME:-$real_home/.mix}" \
  HEX_HOME="${HEX_HOME:-$real_home/.hex}" \
  CONFLUENCE_EXPORT_PORT="$free_port" \
  MIX_ENV=desktop \
  mix test --no-start "$@"
