defmodule Mix.Tasks.Mirror.Blobs.Sweep do
  @shortdoc "Frees attachment bytes that nothing refers to any more"

  @moduledoc """
  Finds blobs no row names — the bytes a crashed run wrote before it recorded
  the row — and frees them, or says what it would free.

      mix mirror.blobs.sweep               # what would go, and how much space
      mix mirror.blobs.sweep --force       # delete it
      mix mirror.blobs.sweep --force --if-older-than 3600

  Only a store that can enumerate its blobs can be swept. The age limit (ten
  minutes by default) protects a sync that has written bytes and not yet the row
  that refers to them.

  Purging from the mirror's trash, replacing a space icon and re-downloading a
  changed attachment already delete their own blobs; this task is for the files
  nobody will ever ask about again.
  """

  use Mix.Task

  alias ConfluencePhxMirror.Blobs.{Store, Sweep}

  @impl true
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args, strict: [force: :boolean, if_older_than: :integer])

    Mix.Task.run("app.start")

    sweep_opts = if opts[:if_older_than], do: [if_older_than: opts[:if_older_than]], else: []

    if opts[:force] do
      {:ok, %{deleted: deleted, bytes: bytes}} = Sweep.sweep(sweep_opts)
      Mix.shell().info("deleted #{deleted} blobs, freeing #{human(bytes)}")
    else
      orphans = Sweep.orphans(sweep_opts)
      bytes = orphans |> Enum.map(&stored_size(&1, [])) |> Enum.sum()

      Mix.shell().info(
        "#{length(orphans)} blobs (#{human(bytes)}) nothing refers to; --force deletes them"
      )
    end
  end

  defp stored_size(key, opts) do
    case Store.size(key, opts) do
      {:ok, size} -> size
      {:error, _reason} -> 0
    end
  end

  defp human(bytes) when bytes < 1024, do: "#{bytes} B"
  defp human(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp human(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 / 1024, 1)} MiB"

  defp human(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 1)} GiB"
end
