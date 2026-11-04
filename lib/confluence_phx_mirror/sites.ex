defmodule ConfluencePhxMirror.Sites do
  @moduledoc """
  Which Confluence site this mirror instance is showing.

  A mirror holds exactly one site's content. Mixing two upstreams in one
  database would put a page from one site next to a page from another under the
  same space key, and nothing in the UI could tell a reader which is which. So a
  site is isolated by *database*, and one running instance serves one site:

      demo snapshot          -> database ..._demo
      https://dled.atlassian.net/wiki -> database ..._dled_atlassian_net
      generated content      -> database ..._synthetic

  Nothing is ever purged when the active site changes: the instance simply opens
  a different database, and the previous site's mirror is untouched. Starting
  the instance against the wrong database is the one mistake that matters, so
  every database records the site it belongs to (`mirror_sites`) and the mirror
  refuses to start when the configuration says otherwise.
  """

  alias ConfluencePhxMirror.Confluence.{DemoSource, Source}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sites.Site

  @demo_key "demo"
  @synthetic_key "synthetic"
  @max_key_length 40

  @type t :: %{
          key: String.t(),
          name: String.t(),
          url: String.t() | nil,
          base_url: String.t() | nil,
          source: module(),
          kind: :demo | :live
        }

  @doc "The site this instance is configured for."
  @spec current() :: t()
  def current do
    source = Source.source()

    %{
      key: key(),
      name: name_for(Source.kind(source), base_url(source)),
      url: web_url(source),
      base_url: base_url(source),
      source: source,
      kind: Source.kind(source)
    }
  end

  @doc """
  The name the mirror goes by: the site's own, not the word "Confluence".

  `https://dled.atlassian.net` is the mirror of `dled`, so a reader can tell
  from the title bar whose wiki they are looking at. The bundled snapshot has no
  site, so it keeps the neutral name.
  """
  @spec name() :: String.t()
  def name, do: current().name

  @doc """
  The address of the original site, e.g. `https://dled.atlassian.net/wiki`.

  `nil` for the bundled demo snapshot, which has no upstream.
  """
  @spec url() :: String.t() | nil
  def url, do: current().url

  @doc "The site's host, for labels: `dled.atlassian.net`."
  @spec host() :: String.t() | nil
  def host, do: host(base_url(Source.source()))

  defp name_for(:demo, _base_url), do: "Confluence Mirror"

  defp name_for(:live, base_url) do
    case host(base_url) do
      nil -> "Confluence Mirror"
      host -> host |> String.split(".") |> hd()
    end
  end

  defp web_url(source) do
    if Code.ensure_loaded?(source) and function_exported?(source, :web_url, 0),
      do: source.web_url(),
      else: nil
  end

  defp host(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _no_host -> nil
    end
  end

  defp host(_base_url), do: nil

  @doc "The active site's key."
  @spec key() :: String.t()
  def key do
    case Source.source() do
      DemoSource -> @demo_key
      ConfluencePhxMirror.Confluence.SyntheticSource -> @synthetic_key
      module -> key_for(base_url(module))
    end
  end

  @doc """
  A stable, filesystem- and database-safe key for a site URL.

      iex> key_for("https://dled.atlassian.net/wiki")
      "dled_atlassian_net"
      iex> key_for(nil)
      "demo"
  """
  @spec key_for(String.t() | nil) :: String.t()
  def key_for(nil), do: @demo_key
  def key_for(""), do: @demo_key

  def key_for(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host |> slug() |> String.slice(0, @max_key_length)

      _no_host ->
        url |> slug() |> String.slice(0, @max_key_length)
    end
  end

  @doc """
  Database name for a site, so each site gets its own.

      iex> database("confluence_phx_mirror_dev", "demo")
      "confluence_phx_mirror_dev_demo"
  """
  @spec database(String.t(), String.t()) :: String.t()
  def database(base, key), do: base <> "_" <> key

  @doc """
  Compares the database's site with the configured one, without deciding what to
  do about a disagreement.

  `verify!/0` refuses by raising, which is right before a sync and right at the
  start of a server that has no one to ask. A window is the other case: there is
  a person in front of it and no console to read, and an app that dies with a
  crash dump explains nothing. So the window asks this, keeps running, and shows
  the answer; nothing is corrupted either way, because reading never mixes sites
  and writing goes through `verify!/0`.
  """
  @spec check() :: :ok | :no_schema | {:conflict, Site.t(), t()}
  def check do
    configured = current()

    case Repo.get(Site, 1) do
      nil ->
        record!(configured)
        :ok

      %Site{key: key} when key == configured.key ->
        :ok

      %Site{} = recorded ->
        {:conflict, recorded, configured}
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres.code == :undefined_table,
        do: :no_schema,
        else: reraise(error, __STACKTRACE__)
  end

  @doc """
  Records the site in the current database, or refuses to continue.

  Called at boot and before a sync so content from one site can never land in
  another site's database. `:no_schema` means the migrations have not run yet;
  the caller decides whether that is fatal.
  """
  @spec verify!() :: :ok | :no_schema
  def verify! do
    case check() do
      :ok ->
        :ok

      :no_schema ->
        :no_schema

      {:conflict, recorded, configured} ->
        raise conflict_message(recorded, configured)
    end
  end

  @doc """
  What a person is told when the folder and the configuration name two sites.

  One text for both audiences: `verify!/0` raises it, and a window's boot check
  raises it when it is the last thing it can do. It names the site the folder
  belongs to, because that is the half nobody typed and nobody remembers.
  """
  @spec conflict_message(Site.t(), t()) :: String.t()
  def conflict_message(recorded, configured) do
    """
    This database belongs to the site #{inspect(recorded.key)} (#{recorded.base_url || "demo"}),
    but the mirror is configured for #{inspect(configured.key)}.

    Refusing to mix two Confluence sites in one mirror. Point the app at the
    right database (`mix mirror.site` prints the one for the current
    configuration) or run this site against a fresh one.
    """
  end

  @conflict_key :site_conflict

  @doc """
  Keeps a disagreement for a screen to explain, and logs it.

  The window's boot check reports rather than refuses — see `Sites.Guard` — and a
  person who is not told what happened cannot fix it. A deployment never calls
  this: it refuses instead, which is what `verify!/0` does.
  """
  @spec report_conflict!(Site.t(), t()) :: :ok
  def report_conflict!(recorded, configured) do
    Application.put_env(:confluence_phx_mirror, @conflict_key, %{
      recorded: recorded.key,
      recorded_url: recorded.base_url,
      configured: configured.key,
      configured_url: configured.base_url
    })
  end

  @doc "The disagreement the boot check reported, or `nil`."
  @spec conflict() :: nil | map()
  def conflict, do: Application.get_env(:confluence_phx_mirror, @conflict_key)

  @doc """
  Asks again, and keeps whichever answer is true now.

  A window keeps running when it disagrees with its folder, so the disagreement
  is not a boot-time fact: saving the right site clears it, and pointing the tool
  at a folder that belongs to another site creates one. Called after the
  connection changes, which is the only thing that can change this answer.
  """
  @spec refresh_conflict() :: :ok | :no_schema
  def refresh_conflict do
    case check() do
      {:conflict, recorded, configured} ->
        report_conflict!(recorded, configured)

      no_conflict ->
        Application.delete_env(:confluence_phx_mirror, @conflict_key)
        no_conflict
    end
  end

  @doc "Writes (or refreshes) the site identity of the current database."
  @spec record!(t()) :: {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def record!(site \\ current()) do
    %Site{}
    |> Site.changeset(%{
      id: 1,
      key: site.key,
      base_url: site.base_url,
      source: inspect(site.source),
      kind: to_string(site.kind)
    })
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :id)
  end

  defp base_url(DemoSource), do: nil

  defp base_url(module) do
    :confluence_phx_mirror
    |> Application.get_env(module, [])
    |> Keyword.get(:base_url)
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> @demo_key
      slug -> slug
    end
  end
end
