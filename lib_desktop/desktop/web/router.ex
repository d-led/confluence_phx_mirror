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

  alias ConfluencePhxMirror.Desktop.{Archive, Jobs, Mirror, Settings, Spaces, Web.Page}
  alias ConfluencePhxMirror.Export

  # A site can have a hundred thousand spaces. The screen renders a page of them
  # and says how many it is not showing; nobody scrolls to the hundred
  # thousandth, and rendering it would cost the request that found it.
  @page_size 200

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded]

  # The mirror itself. Served as files from the folder the exporter wrote, so
  # what the window reads is byte for byte what the archive contains. The folder
  # is a function, not a path: it is resolved per request, because the workspace
  # folder is something a person can change in the form, and a path read at
  # compile time is yesterday's answer.
  plug Plug.Static,
    at: "/site",
    from: {Archive, :dir, []},
    gzip: false,
    raise_on_missing_assets: false

  plug :dispatch

  # The window opens here, configured or not: a tool that hides behind a form may
  # still have a mirror worth reading, and the folder can be wrong.
  get "/" do
    send_resp(conn, 200, Page.home())
  end

  get "/setup" do
    send_resp(conn, 200, Page.setup(%{}))
  end

  post "/setup" do
    attrs = %{
      site: conn.params["site"],
      email: conn.params["email"],
      secret: conn.params["secret"],
      root: conn.params["root"]
    }

    case Settings.configure(attrs) do
      :ok ->
        conn |> put_resp_header("location", "/") |> send_resp(303, "")

      {:error, reason} ->
        # 422 rather than a redirect: the browser keeps the form it submitted,
        # and the message is about what it sent.
        send_resp(
          conn,
          422,
          Page.setup(%{
            site: attrs.site,
            email: attrs.email,
            root: attrs.root,
            error: explain(reason)
          })
        )
    end
  end

  get "/state" do
    send_resp(conn, 200, JSON.encode_to_iodata!(state()))
  end

  get "/spaces" do
    query = String.trim(conn.params["q"] || "")

    case Spaces.list() do
      {:ok, spaces} ->
        matching = filter(spaces, query)

        send_resp(
          conn,
          200,
          Page.spaces(Enum.take(matching, @page_size), Mirror.page_counts(), %{
            query: query,
            known: length(spaces),
            matching: length(matching),
            status: if(Spaces.state().refreshing?, do: "Refreshing the space list…"),
            run: Jobs.status()
          })
        )

      # Nothing is fetched in the request: no screen waits on Confluence, and a
      # slow site shows what is happening instead of a blank window.
      :loading ->
        send_resp(
          conn,
          200,
          Page.loading("Asking #{Settings.site() || "the site"} for its spaces.")
        )

      {:error, reason} ->
        send_resp(conn, 502, Page.problem(reason))
    end
  end

  # A run is started and then left alone: the screen it leaves you on follows
  # it, so a mirror that takes an hour does not take an hour of your attention.
  post "/mirror" do
    started(conn, Jobs.start_mirror([conn.params["space"]], conn.params["space"]))
  end

  post "/mirror_all" do
    query = String.trim(conn.params["q"] || "")

    case Spaces.list() do
      {:ok, spaces} ->
        keys = spaces |> filter(query) |> Enum.map(& &1.key)

        label =
          if query == "",
            do: "all #{length(keys)} spaces",
            else: "#{length(keys)} spaces matching #{inspect(query)}"

        started(conn, Jobs.start_mirror(keys, label))

      # Still being fetched: send them back to the screen that shows it, rather
      # than mirroring a list that is not there yet.
      _loading_or_failed ->
        redirect_to(conn, "/spaces")
    end
  end

  # The live filter. Served rather than inlined: the page is generated HTML, but
  # a script tag pointing at one file is still the only copy of it.
  get "/assets/app.js" do
    conn
    |> put_resp_content_type("text/javascript")
    |> send_resp(200, Page.script())
  end

  get "/mirror" do
    send_resp(conn, 200, Page.mirror(Jobs.status()))
  end

  # The pages, as a folder the window can browse. Writing them is the same work
  # the archive does, so it is started and followed rather than waited on.
  #
  # Asking for the mirror is asking to read it, so a copy that exists is served:
  # a redirect, one hop, no screen in between. A catalogue nobody has written
  # yet is written now — the first visit waits on the same job every later visit
  # finds finished — and only a catalogue with no pages at all has nothing to
  # offer. This is why "Mirror" in the bar lands on content, during a sync or
  # after one: the published copy is last night's, and it is readable while the
  # new one is being fetched.
  get "/site" do
    case Archive.publish_status() do
      :publishing ->
        send_resp(conn, 200, Page.site(:building))

      {:error, message} ->
        send_resp(conn, 500, Page.site({:error, message}))

      _idle_or_done ->
        cond do
          Archive.published?() ->
            conn |> put_resp_header("location", "/site/index.html") |> send_resp(302, "")

          Mirror.pages?() ->
            _ = Archive.publish_async()
            send_resp(conn, 200, Page.site(:building))

          true ->
            send_resp(conn, 200, Page.site(:absent))
        end
    end
  end

  post "/site" do
    _ = Archive.publish_async()
    conn |> put_resp_header("location", "/site") |> send_resp(303, "")
  end

  # The archive is a file that leaves the tool, so it is built first and then
  # sent as a file: a length and ranges are what a download needs to be
  # resumed, and generating the bytes per request gives neither.
  get "/export" do
    send_resp(conn, 200, Page.export(Archive.status(), Archive.path()))
  end

  post "/export" do
    _ = Archive.prepare()
    conn |> put_resp_header("location", "/export") |> send_resp(303, "")
  end

  get "/export/site.zip" do
    case Archive.status() do
      {:ready, %{bytes: bytes}} ->
        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header("content-disposition", attachment())
        |> send_file(200, Archive.path(), 0, bytes)

      _not_ready ->
        send_resp(conn, 404, "The archive has not been built yet.")
    end
  end

  # What the banner polls. Small and frequent, which is why it is its own route
  # rather than a page.
  get "/status" do
    send_resp(conn, 200, JSON.encode_to_iodata!(Jobs.status()))
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

  # Where a start leaves the screen. Started: the list, which follows the run.
  # Refused: the run screen, which says which run is going or what stopped it —
  # a redirect that hides the answer is how a button appears to do nothing.
  defp started(conn, {:ok, :started}), do: redirect_to(conn, "/spaces")
  defp started(conn, {:error, :busy}), do: redirect_to(conn, "/mirror")
  defp started(conn, {:error, :no_worker}), do: redirect_to(conn, "/mirror")
  defp started(conn, {:error, :nothing_to_do}), do: redirect_to(conn, "/spaces")

  defp redirect_to(conn, path) do
    conn |> put_resp_header("location", path) |> send_resp(303, "")
  end

  # Case-insensitive, on the key as well as the name, and every word has to
  # match — the same rule the mirror's own search uses, so a phrase narrows
  # rather than being one odd substring. A person looking for ENG types ENG,
  # not "Engineering".
  defp filter(spaces, ""), do: spaces

  defp filter(spaces, query) do
    words = query |> String.downcase() |> String.split(~r/\s+/u, trim: true)

    Enum.filter(spaces, fn space ->
      haystack = String.downcase(space.name) <> " " <> String.downcase(space.key)
      Enum.all?(words, &String.contains?(haystack, &1))
    end)
  end

  # The name the browser files it under: the site's own name and the moment it
  # was copied, so two copies of one site are two files rather than a prompt.
  defp attachment do
    ~s(attachment; filename="#{Export.site_archive_name()}")
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

  defp explain({:not_writable, path, reason}),
    do: "The folder #{path} exists but cannot be written to (#{reason})."
end
