#!/usr/bin/env bash
#
# Starts the desktop export tool: the same code as the server, under its own
# environment (see docs/desktop-tool.md).
#
#   scripts/start-desktop.sh                  an IEx session with the tool's tree
#   scripts/start-desktop.sh --folder PATH    point the run at PATH, then start
#   scripts/start-desktop.sh --where          print the folders in use, then exit
#
# The folder holds the catalogue and the attachments. It is remembered in a
# settings file rather than in config, because it is chosen after the app exists.
# Nothing here touches the server's database or its `MIX_ENV`.
#
# Exit status is non-zero if the tool cannot start, so it can sit in a pipeline.

set -euo pipefail

cd "$(dirname "$0")/.."

mode=start
folder=""

usage() {
  sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --folder) folder="${2:?--folder needs a path}"; shift 2 ;;
    --where) mode=where; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

export MIX_ENV=desktop

# `only: :desktop` is why this is a separate fetch: the server's `mix deps.get`
# never sees the SQLite adapter, and a checkout that has only run that has not
# got it yet.
mix deps.get >/dev/null

# `--no-start` on purpose: these two read and write a settings file, and booting
# the app first would open the catalogue in the old folder — creating a database
# file somebody did not ask for, one line before it is abandoned.
where() {
  mix run --no-start -e '
    alias ConfluencePhxMirror.Desktop.Settings

    IO.puts("id:          #{Settings.id()}")
    IO.puts("folder:      #{Settings.root()}")
    IO.puts("catalogue:   #{Settings.database()}")
    IO.puts("attachments: #{Settings.blobs()}")
    IO.puts("site:        #{Settings.site() || "(not set)"}")
    IO.puts("account:     #{Settings.email() || "(bearer token)"}")

    readiness =
      case Settings.readiness() do
        :ready -> "ready"
        {:needs, missing} -> "needs " <> Enum.join(missing, ", ")
      end

    IO.puts("readiness:   #{readiness}")
  '
}
# The same question the desktop shell will ask the sidecar before deciding
# between the configuration form and the main screen.
readiness() {
  mix run --no-start -e '
    IO.write(
      case ConfluencePhxMirror.Desktop.Settings.readiness() do
        :ready -> "ready"
        {:needs, missing} -> "needs:" <> Enum.join(missing, ",")
      end
    )
  '
}

# The configuration dialog, for the CLI. The answers are piped to the child
# process rather than passed as arguments or environment: a token on a command
# line is a token in `ps`.
configure() {
  local site email secret

  read -r -p "Confluence site URL: " site
  read -r -p "Account e-mail (blank for a personal access token): " email
  read -r -s -p "API token (input hidden): " secret
  echo

  printf '%s\n%s\n%s\n' "$site" "$email" "$secret" | mix run --no-start -e '
    read_line = fn -> IO.read(:stdio, :line) |> to_string() |> String.trim() end

    attrs = %{site: read_line.(), email: read_line.(), secret: read_line.()}

    case ConfluencePhxMirror.Desktop.Settings.configure(attrs) do
      {:ok, _id} -> IO.puts("workspace configured")
      {:error, reason} ->
        IO.puts(:standard_error, "cannot configure: #{inspect(reason)}")
        System.halt(1)
    end
  '
}

case "$mode" in
  where)
    where
    ;;
  start)
    if [[ -n "$folder" ]]; then
      # The tool says precisely what is wrong with a folder — it cannot be
      # created, it refuses a write — so the message is passed through rather
      # than replaced with "invalid folder".
      case "$(realpath "$folder" 2>/dev/null || echo "$folder")" in
        /*) ;;
        *) echo "--folder needs an absolute path, got: $folder" >&2; exit 64 ;;
      esac

      if ! CONFLUENCE_EXPORT_WORKSPACE="$folder" mix run --no-start -e '
        case ConfluencePhxMirror.Desktop.Settings.choose_root(
               System.fetch_env!("CONFLUENCE_EXPORT_WORKSPACE")
             ) do
          :ok -> :ok
          {:error, reason} ->
            IO.puts(:standard_error, "cannot use that folder: #{inspect(reason)}")
            System.halt(1)
        end
      '; then
        exit 1
      fi

      where
    fi

    # Not configured: this is the point where the desktop shell shows the
    # configuration form instead of the main screen. From a terminal it is the
    # same form, asking the same question of the same module.
    if [[ "$(readiness)" != "ready" ]]; then
      echo "this workspace is not configured yet"
      configure || exit 1
      echo
      where
    fi

    echo "starting the desktop tool — ConfluencePhxMirror.Desktop.Application, SQLite"
    exec iex -S mix
    ;;
esac
