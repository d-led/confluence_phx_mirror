defmodule Mix.Tasks.Confluence.Seed do
  @shortdoc "Copies the demo snapshot into a real Confluence space (dry run by default)"

  @moduledoc """
  Seeds a real Confluence space with the bundled demo pages.

      CM_SOURCE=http CM_CONFLUENCE_SITE=https://acme.atlassian.net \\
      CM_ATL_EMAIL=you@acme.com CM_ATL_TOKEN=… \\
      mix confluence.seed --space ENG

  Without `--confirm` this is a dry run: it prints what it would create and
  writes nothing. With `--confirm` it creates the missing pages and labels each
  one `confluence-mirror-seed`; pages that exist but do not carry that label are
  reported and left untouched, so running the task twice creates nothing new.

  The task refuses to write unless the token's account can administer the space,
  because seeding is an authoring action, not a reading one.
  """

  use Mix.Task

  alias ConfluencePhxMirror.Confluence.{HttpSource, Seed, Source}

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(args, strict: [space: :string, from: :string, confirm: :boolean])

    reject_invalid(invalid)

    space_key =
      opts[:space] || Mix.raise("Pass the target space, for example `--space ENG`.")

    from = opts[:from]

    ensure_live_source!()
    ensure_admin!(space_key)

    if opts[:confirm] do
      seed(space_key, from)
    else
      plan(space_key, from)
    end
  end

  defp plan(space_key, from) do
    case Seed.plan(space_key, from: from) do
      {:ok, decisions} ->
        Mix.shell().info(header(space_key, "planned"))
        print(decisions)
        Mix.shell().info("\nDry run: nothing was written. Re-run with --confirm to create.")

      {:error, reason} ->
        Mix.raise("Could not read space #{space_key}: #{inspect(reason)}")
    end
  end

  defp seed(space_key, from) do
    case Seed.run(space_key, from: from) do
      {:ok, decisions} ->
        Mix.shell().info(header(space_key, "done"))
        print(decisions)

      {:error, :not_admin} ->
        Mix.raise(
          "The API token's account cannot administer space #{space_key}, so the seeder refuses to write."
        )

      {:error, reason} ->
        Mix.raise("Seeding stopped: #{inspect(reason)}")
    end
  end

  defp print(decisions) do
    Enum.each(decisions, fn decision ->
      Mix.shell().info(
        "  #{symbol(decision.action)} #{decision.title}#{page_note(decision)}#{detail(decision)}"
      )
    end)
  end

  defp symbol(:create), do: "+"
  defp symbol(:exists), do: "="
  defp symbol(:foreign), do: "!"
  defp symbol(:extras), do: "~"
  defp symbol(:skipped), do: "-"

  defp detail(%{detail: detail}), do: " — " <> detail
  defp detail(_decision), do: ""
  defp page_note(%{page_id: nil}), do: ""
  defp page_note(%{page_id: id}) when is_binary(id) or is_integer(id), do: " (#{id})"
  defp page_note(_decision), do: ""

  defp header(space_key, verb), do: "\nSpace #{space_key}: #{verb} #{Seed.label()} pages\n"

  defp reject_invalid([]), do: :ok
  defp reject_invalid(invalid), do: Mix.raise("Unknown options: #{inspect(invalid)}")

  defp ensure_live_source! do
    if Source.source() != HttpSource do
      Mix.raise("""
      The configured source is #{inspect(Source.source())}: there is no site to seed.
      Re-run with CM_SOURCE=http.
      """)
    end
  end

  defp ensure_admin!(space_key) do
    case HttpSource.probe() do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "Cannot reach Confluence as the configured account (#{inspect(reason)}). " <>
            "Seeding space #{space_key} needs a token with Confluence write access."
        )
    end
  end
end
