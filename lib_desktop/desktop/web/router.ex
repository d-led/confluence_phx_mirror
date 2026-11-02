defmodule ConfluencePhxMirror.Desktop.Web.Router do
  @moduledoc """
  The sidecar's few routes: the configuration form, and what the shell asks to
  decide whether to show it.

  Everything here is answered on loopback, for the webview the tool itself
  opened. There is no session and no login, because there is one reader and the
  window is the only way in — which is also why the token in the form is written
  straight to the OS credential store and never echoed back.
  """

  use Plug.Router

  alias ConfluencePhxMirror.Desktop.{Jobs, Mirror, Settings, Web.Page}

  # A site can have a hundred thousand spaces. The screen renders a page of them
  # and says how many it is not showing; nobody scrolls to the hundred
  # thousandth, and rendering it would cost the request that found it.
  @page_size 200

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded]
  plug :dispatch

  get "/" do
    if Settings.configured?() do
      send_resp(conn, 200, Page.home())
    else
      conn |> put_resp_header("location", "/setup") |> send_resp(302, "")
    end
  end

  get "/setup" do
    send_resp(conn, 200, Page.setup(%{}))
  end

  post "/setup" do
    attrs = %{
      site: conn.params["site"],
      email: conn.params["email"],
      secret: conn.params["secret"]
    }

    case Settings.configure(attrs) do
      {:ok, _workspace_id} ->
        conn |> put_resp_header("location", "/") |> send_resp(303, "")

      {:error, reason} ->
        # 422 rather than a redirect: the browser keeps the form it submitted,
        # and the message is about what it sent.
        send_resp(conn, 422, Page.setup(%{site: attrs.site, email: attrs.email, error: explain(reason)}))
    end
  end

  get "/state" do
    send_resp(conn, 200, JSON.encode_to_iodata!(state()))
  end

  get "/spaces" do
    query = String.trim(conn.params["q"] || "")

    case Mirror.spaces() do
      {:ok, spaces} ->
        matching = filter(spaces, query)

        send_resp(
          conn,
          200,
          Page.spaces(Enum.take(matching, @page_size), Mirror.page_counts(), %{
            query: query,
            known: length(spaces),
            matching: length(matching)
          })
        )

      {:error, reason} ->
        send_resp(conn, 502, Page.problem(reason))
    end
  end

  post "/mirror" do
    case Jobs.start_mirror([conn.params["space"]], conn.params["space"]) do
      {:ok, :started} -> conn |> put_resp_header("location", "/mirror") |> send_resp(303, "")
      # A run already going: watching it is the same answer they wanted.
      {:error, _busy} -> conn |> put_resp_header("location", "/mirror") |> send_resp(303, "")
    end
  end

  post "/mirror_all" do
    with {:ok, spaces} <- Mirror.spaces(),
         keys = Enum.map(spaces, & &1.key),
         {:ok, :started} <- Jobs.start_mirror(keys, "all #{length(keys)} spaces") do
      conn |> put_resp_header("location", "/mirror") |> send_resp(303, "")
    else
      _nothing_or_busy -> conn |> put_resp_header("location", "/mirror") |> send_resp(303, "")
    end
  end

  get "/mirror" do
    send_resp(conn, 200, Page.mirror(Jobs.status()))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp state do
    case Settings.readiness() do
      :ready -> %{readiness: "ready", site: Settings.site()}
      {:needs, missing} -> %{readiness: "needs", missing: Enum.map(missing, &Atom.to_string/1)}
    end
  end

  # Case-insensitive, on the key as well as the name: a person looking for ENG
  # types ENG, not "Engineering".
  defp filter(spaces, ""), do: spaces

  defp filter(spaces, query) do
    needle = String.downcase(query)

    Enum.filter(spaces, fn space ->
      String.contains?(String.downcase(space.name) <> " " <> String.downcase(space.key), needle)
    end)
  end

  # The reason as a sentence, because the form shows it to a person.
  #
  # These four are the whole set `Settings.configure/1` can return, and the
  # compiler says so: it reports any further clause as unreachable. A new
  # failure worth explaining should fail loudly here rather than be swallowed by
  # a catch-all.
  defp explain(:site_required), do: "A site URL is needed."
  defp explain(:secret_required), do: "A token is needed."
  defp explain({:invalid_site, site}), do: "#{site} is not a URL this tool can use."

  defp explain({:cannot_create, path, reason}),
    do: "The folder #{path} could not be created (#{reason})."
end
