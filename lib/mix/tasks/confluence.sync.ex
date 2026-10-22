defmodule Mix.Tasks.Confluence.Sync do
  @shortdoc "Mirrors Confluence content into the local database"

  @moduledoc """
  Runs a sync and prints a summary.

      mix confluence.sync
      mix confluence.sync --mode incremental
      mix confluence.sync --mode space --space ENG
      mix confluence.sync --mode page --page 1002
      mix confluence.sync --mode incremental --since 2026-10-20T00:00:00Z

  Modes map to the same pipeline the scheduler and webhooks use; the source is
  whatever `CM_SOURCE` selects (`demo` by default, `http` for a real site).
  """

  use Mix.Task

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Sync

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [mode: :string, space: :string, page: :integer, since: :string]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    {mode, sync_opts} = build(opts)

    Mix.shell().info("Syncing (#{mode}) from #{inspect(Source.source())}…")

    case Sync.run(mode, sync_opts ++ [trigger: "mix confluence.sync"]) do
      {:ok, run} ->
        print_summary(run)
        if run.status == "failed", do: exit({:shutdown, 1})
    end
  end

  defp build(opts) do
    case Keyword.get(opts, :mode, "snapshot") do
      "snapshot" ->
        {:snapshot, []}

      "incremental" ->
        {:incremental, since_opts(opts)}

      "space" ->
        {:space, [space_key: required!(opts, :space)]}

      "page" ->
        {:page, [confluence_id: required!(opts, :page)]}

      other ->
        Mix.raise("Unknown --mode #{inspect(other)} (snapshot, incremental, space, page)")
    end
  end

  defp since_opts(opts) do
    case opts[:since] do
      nil ->
        []

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> [since: datetime]
          _ -> Mix.raise("--since must be an ISO 8601 timestamp, got #{inspect(value)}")
        end
    end
  end

  defp required!(opts, key) do
    Keyword.get(opts, key) || Mix.raise("--#{key} is required for this mode")
  end

  defp print_summary(run) do
    Mix.shell().info("""
    #{run.status} · #{run.mode} · #{run.source}
    spaces: #{run.stats["spaces"]}  pages: #{run.stats["pages"]}  attachments: #{run.stats["attachments"]}
    comments: #{run.stats["comments"]}  links: #{run.stats["links"]}  notifications: #{run.stats["notifications"]}
    errors: #{length(run.stats["errors"] || [])}
    """)

    if run.error, do: Mix.shell().error(run.error)
  end
end
