defmodule ConfluencePhxMirror.Mcp.Tools.Index do
  @moduledoc """
  `confluence_index_status`: what the mirror has ingested, and when.

  This is the one tool that answers a question about the *mirror* rather than
  about the wiki, so it is administrator material in exactly the way `/admin`
  is: sync runs, per-space read times and totals. A reader's token must not turn
  that into content, so the tool asks `Scope.admin?/1` before reading anything
  and refuses everyone else — the same answer `/admin` gives, in the same place
  the answer is decided.

  What it is for: "what was indexed last", "when was this space last read",
  "did the last run fail". Those are the questions an assistant asked to help
  operate the mirror will hit first.
  """

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Mcp.Args
  alias ConfluencePhxMirror.Mcp.Tools.Pages
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.SyncRun

  @doc "`confluence_index_status`: administrator-only ingestion history."
  def status(args, %Scope{} = scope) do
    if Scope.admin?(scope) do
      report(args)
    else
      {:error, "Only mirror administrators can read the index status."}
    end
  end

  defp report(args) do
    with {:ok, key} <- Args.optional(args, "space_key"),
         {:ok, limit} <- Args.integer(args, "limit", default: 10, min: 1, max: 50),
         {:ok, count} <- Args.integer(args, "runs", default: 5, min: 0, max: 20) do
      spaces = Mirror.spaces_by_last_sync(limit, key: key)
      runs = if count == 0, do: [], else: Mirror.recent_sync_runs(count)

      {:ok,
       %{
         text: text(spaces, runs, key),
         structured: %{
           "last_successful" => run(Mirror.last_successful_sync_run()),
           "runs" => Enum.map(runs, &run/1),
           "spaces" => Enum.map(spaces, &space/1),
           "totals" => totals()
         }
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp text(spaces, runs, key) do
    [running_line(runs), runs_text(runs), spaces_text(spaces, key)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp running_line([%SyncRun{status: "running"} = run | _rest]) do
    "A sync is running: #{run.mode}, started #{Pages.iso(run.started_at)}."
  end

  defp running_line(_runs), do: nil

  defp runs_text([]), do: nil

  defp runs_text(runs) do
    "## Recent sync runs\n\n" <>
      Enum.map_join(runs, "\n", fn run ->
        "- #{Pages.iso(run.started_at) || "unknown"} — #{run.mode} — #{run.status}" <>
          if(run.error, do: " — #{run.error}", else: "") <>
          counts(run)
      end)
  end

  defp counts(run) do
    summary = SyncRun.summary(run)
    "\n  #{summary.listed} listed, #{summary.changed} changed, #{summary.errors} errors"
  end

  defp spaces_text([], nil), do: "No spaces are mirrored."

  defp spaces_text([], key) do
    "Space #{String.upcase(key)} is not mirrored."
  end

  defp spaces_text(spaces, _key) do
    "## Spaces, most recently indexed first\n\n" <>
      Enum.map_join(spaces, "\n", fn {key, name, synced_at, pages} ->
        "- #{Pages.iso(synced_at) || "never"} — #{key} (#{name}) — #{pages} pages"
      end)
  end

  defp totals do
    Mirror.stats()
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  # ---------------------------------------------------------------------------
  # Structured content
  # ---------------------------------------------------------------------------

  defp run(nil), do: nil

  defp run(%SyncRun{} = run) do
    %{
      "mode" => run.mode,
      "status" => run.status,
      "scope" => run.scope,
      "started" => Pages.iso(run.started_at),
      "finished" => Pages.iso(run.finished_at),
      "error" => run.error
    }
    |> Map.merge(Map.new(SyncRun.summary(run), fn {key, value} -> {to_string(key), value} end))
  end

  defp space({key, name, synced_at, pages}) do
    %{"key" => key, "name" => name, "synced_at" => Pages.iso(synced_at), "pages" => pages}
  end
end
