defmodule ConfluencePhxMirror.Sites do
  @moduledoc """
  Which Confluence site this mirror instance is showing.

  A mirror holds exactly one site's content. Mixing two upstreams in one
  database would put a page from one site next to a page from another under the
  same space key, and nothing in the UI could tell a reader which is which. So a
  site is isolated by *database*, and one running instance serves one site:

      demo snapshot          -> database ..._demo
      https://dled.atlassian.net/wiki -> database ..._dled_atlassian_net

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
  @max_key_length 40

  @type t :: %{key: String.t(), base_url: String.t() | nil, source: module(), kind: :demo | :live}

  @doc "The site this instance is configured for."
  @spec current() :: t()
  def current do
    source = Source.source()

    %{
      key: key(),
      base_url: base_url(source),
      source: source,
      kind: Source.kind(source)
    }
  end

  @doc "The active site's key."
  @spec key() :: String.t()
  def key do
    case Source.source() do
      DemoSource -> @demo_key
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
  Records the site in the current database, or refuses to continue.

  Called at boot and before a sync so content from one site can never land in
  another site's database. `:no_schema` means the migrations have not run yet;
  the caller decides whether that is fatal.
  """
  @spec verify!() :: :ok | :no_schema
  def verify! do
    configured = current()

    case Repo.get(Site, 1) do
      nil ->
        record!(configured)
        :ok

      %Site{key: key} when key == configured.key ->
        :ok

      %Site{key: key, base_url: base_url} ->
        raise """
        This database belongs to the site #{inspect(key)} (#{base_url || "demo"}),
        but the mirror is configured for #{inspect(configured.key)}.

        Refusing to mix two Confluence sites in one mirror. Point the app at the
        right database (`mix mirror.site` prints the one for the current
        configuration) or run this site against a fresh one.
        """
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres.code == :undefined_table,
        do: :no_schema,
        else: reraise(error, __STACKTRACE__)
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
