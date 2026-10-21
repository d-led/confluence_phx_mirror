defmodule Mix.Tasks.Mirror.Site do
  @shortdoc "Shows (or creates) the database of the configured Confluence site"

  @moduledoc """
  Prints which site this instance is configured for, which database holds it and
  whether that database already exists.

      mix mirror.site            # status of the active site
      mix mirror.site --create   # create and migrate the site's database

  Every site gets its own database, so switching between the bundled demo
  snapshot and a real Confluence site never mixes their content:

      CM_SOURCE=demo                         mix mirror.site
        site     demo (bundled demo snapshot)
        database confluence_phx_mirror_dev_demo   exists

      CM_CONFLUENCE_SITE=https://acme.atlassian.net \\
      CM_ATL_EMAIL=… CM_ATL_TOKEN=…          mix mirror.site --create

  Nothing is dropped when the site changes: the other database stays where it is
  and becomes active again when the configuration points back at it.
  """

  use Mix.Task

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.{Repo, Sites}

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: [create: :boolean])
    reject_invalid(invalid)
    Mix.Task.run("app.config")

    site = Sites.current()
    database = Repo.config()[:database]
    exists? = database_exists?(database)

    report(site, database, exists?)

    if Keyword.get(opts, :create, false) and not exists? do
      Mix.shell().info("\nCreating #{database} and running the migrations...")
      Mix.Task.run("ecto.create", ["--quiet"])
      Mix.Task.run("ecto.migrate", [])
    end
  end

  defp report(site, database, exists?) do
    Mix.shell().info("""
    site     #{site.key} (#{source_label(site)})
    database #{database}   #{if exists?, do: "exists", else: "missing — create it with --create"}
    """)
  end

  defp source_label(%{kind: :demo}), do: "bundled demo snapshot"
  defp source_label(%{base_url: url}) when is_binary(url) and url != "", do: url
  defp source_label(_site), do: inspect(Source.source())

  # Asks the server rather than the repo: the database this task reports on may
  # not exist yet, which is exactly the case it has to describe.
  defp database_exists?(database) do
    config = Repo.config()
    {:ok, _started} = Application.ensure_all_started(:postgrex)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port],
        username: config[:username],
        password: config[:password],
        database: "postgres"
      )

    %{rows: rows} =
      Postgrex.query!(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [database])

    GenServer.stop(conn)
    rows != []
  rescue
    error -> Mix.raise("Could not reach Postgres: #{Exception.message(error)}")
  end

  defp reject_invalid([]), do: :ok
  defp reject_invalid(invalid), do: Mix.raise("Unknown options: #{inspect(invalid)}")
end
