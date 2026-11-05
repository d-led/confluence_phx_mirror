defmodule ConfluencePhxMirror.Mcp.Tools.Configuration do
  @moduledoc """
  `confluence_mirror_configuration`: what this mirror is set up to do.

  The first questions an operator asks an assistant are not about content: which
  site is mirrored, how often it is read, when it last ran, how much is in there
  — and, in the desktop tool, which folder keeps the catalogue and which address
  an assistant should be pointed at. That is configuration, so it is
  administrator material in the same way `/admin/settings` is, and a reader's
  token is refused rather than shown a summary of somebody else's deployment.

  What it never returns is the credential that reaches Confluence. A tool that
  can read a secret puts that secret in a transcript, and a transcript is a log.
  """

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.{Mirror, Settings, Sites}
  alias ConfluencePhxMirror.Sync.SyncRun

  @doc "`confluence_mirror_configuration`: administrator-only configuration."
  def current(_args, %Scope{} = scope) do
    if Scope.admin?(scope) do
      report()
    else
      {:error, "Only mirror administrators can read the configuration."}
    end
  end

  defp report do
    structured =
      %{
        "site" => site(),
        "sync" => sync(),
        "content" => content(),
        "workspace" => workspace()
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, %{text: text(structured), structured: structured}}
  end

  defp site do
    %{"name" => Sites.name(), "url" => Sites.url(), "host" => Sites.host()}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sync do
    %{
      "interval_seconds" => Settings.sync_interval_seconds(),
      "reconcile_interval_seconds" => Settings.reconcile_interval_seconds(),
      "last_successful_run" => run(Mirror.last_successful_sync_run())
    }
  end

  defp run(nil), do: nil

  defp run(%SyncRun{} = run) do
    %{
      "id" => run.id,
      "mode" => run.mode,
      "status" => run.status,
      "started_at" => iso(run.started_at),
      "finished_at" => iso(run.finished_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp content do
    %{"spaces" => Mirror.count_spaces(), "absent_pages" => Mirror.count_absent()}
  end

  # A desktop tool knows what a deployment cannot: where the catalogue lives, the
  # port the window answers on, the spaces somebody ticked, the address an
  # assistant is pointed at. It hands that over through this hook, because
  # `lib_desktop` is a different build and this module must not reach into it —
  # a deployment leaves the hook unset and the key out of the answer.
  defp workspace do
    case Application.get_env(:confluence_phx_mirror, :workspace_info) do
      fun when is_function(fun, 0) ->
        fun.()
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      _deployment ->
        nil
    end
  end

  defp text(structured) do
    site = structured["site"]
    sync = structured["sync"]
    content = structured["content"]

    [
      "**#{site["name"]}**#{if site["url"], do: " — #{site["url"]}", else: ""}",
      "#{content["spaces"]} spaces mirrored, #{content["absent_pages"]} pages absent from the site",
      "sync every #{duration(sync["interval_seconds"])}, " <>
        "verify every #{duration(sync["reconcile_interval_seconds"])}",
      last_run(sync["last_successful_run"]),
      workspace_text(structured["workspace"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp last_run(nil), do: "no successful sync recorded yet"

  defp last_run(run) do
    "last successful sync: ##{run["id"]} (#{run["mode"]}), finished #{run["finished_at"]}"
  end

  defp workspace_text(nil), do: nil

  defp workspace_text(workspace) do
    parts =
      [
        workspace["root"] && "workspace: #{workspace["root"]}",
        workspace["site"] && "site: #{workspace["site"]}",
        workspace["mcp_url"] && "assistant endpoint: #{workspace["mcp_url"]}"
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  defp duration(seconds) when is_integer(seconds) and seconds >= 3600 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h#{if minutes > 0, do: " #{minutes}m", else: ""}"
  end

  defp duration(seconds) when is_integer(seconds) and seconds >= 60,
    do: "#{div(seconds, 60)}m"

  defp duration(seconds), do: "#{seconds}s"
end
