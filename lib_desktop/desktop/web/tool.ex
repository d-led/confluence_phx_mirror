defmodule ConfluencePhxMirror.Desktop.Web.Tool do
  @moduledoc """
  The tool's own screens, under `/__tool`: the connection, and the run that
  copies a space into the catalogue.

  Everything a reader looks at is the mirror's own — the same LiveViews, the
  same admin area, at the same paths — and it is served by the endpoint mounted
  beside this router (see `ConfluencePhxMirror.Desktop.Web.Dispatch`). What is
  left here is what a single-user tool has and a deployment does not: where its
  site is and which token reaches it, and a run that goes straight into the
  catalogue instead of through a queue.

  Everything is answered on loopback, for the webview the tool itself opened.
  There is no sign-in, because there is one reader and the window is the only
  way in — which is also why the token in the form is written straight to the
  OS credential store and never echoed back.
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
  plug :dispatch

  # The tool's home: what this workspace is, and the way into the mirror, its
  # admin area, and the two screens that are this router's own.
  get "/__tool" do
    send_resp(conn, 200, Page.home())
  end

  get "/__tool/setup" do
    send_resp(conn, 200, Page.setup(%{}))
  end

  post "/__tool/setup" do
    attrs = %{
      site: conn.params["site"],
      email: conn.params["email"],
      secret: conn.params["secret"],
      root: conn.params["root"]
    }

    case Settings.configure(attrs) do
      :ok ->
        # The connection is what the mirror screens were waiting for, so saving
        # it lands on the mirror rather than back on the form.
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

  get "/__tool/state" do
    send_resp(conn, 200, JSON.encode_to_iodata!(state()))
  end

  # Reveals the workspace in the desktop's own file manager. It is the one place
  # this app acts on the person's machine, and it only ever *shows* a folder it
  # already owns: deleting the catalogue is how somebody starts over, and that
  # decision belongs in Finder, where it can be seen and undone, not behind a
  # button in here.
  post "/__tool/open-folder" do
    case reveal(Settings.root()) do
      :ok ->
        conn |> put_resp_header("location", "/__tool") |> send_resp(303, "")

      {:error, reason} ->
        send_resp(conn, 500, Page.folder_problem(reason))
    end
  end

  get "/__tool/spaces" do
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
  post "/__tool/mirror" do
    started(conn, Jobs.start_mirror([conn.params["space"]], conn.params["space"]))
  end

  post "/__tool/mirror_all" do
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
        redirect_to(conn, "/__tool/spaces")
    end
  end

  # The live filter. Served rather than inlined: the page is generated HTML, but
  # a script tag pointing at one file is still the only copy of it.
  get "/__tool/assets/app.js" do
    conn
    |> put_resp_content_type("text/javascript")
    |> send_resp(200, Page.script())
  end

  get "/__tool/mirror" do
    send_resp(conn, 200, Page.mirror(Jobs.status()))
  end

  # The archive is a file that leaves the tool, so it is built first and then
  # sent as a file: a length and ranges are what a download needs to be
  # resumed, and generating the bytes per request gives neither.
  get "/__tool/export" do
    send_resp(conn, 200, Page.export(Archive.status(), Archive.path()))
  end

  post "/__tool/export" do
    _ = Archive.prepare()
    conn |> put_resp_header("location", "/__tool/export") |> send_resp(303, "")
  end

  get "/__tool/export/site.zip" do
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
  get "/__tool/status" do
    send_resp(conn, 200, JSON.encode_to_iodata!(Jobs.status()))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # What the shell asks to decide whether to show the form: the same question
  # the first-run redirect asks, answered as data.
  defp state do
    case Settings.readiness() do
      :ready -> %{readiness: "ready", site: Settings.site()}
      {:needs, missing} -> %{readiness: "needs", missing: Enum.map(missing, &Atom.to_string/1)}
    end
  end

  # Where a start leaves the screen. Started: the list, which follows the run.
  # Refused: the run screen, which says which run is going or what stopped it —
  # a redirect that hides the answer is how a button appears to do nothing.
  defp started(conn, {:ok, :started}), do: redirect_to(conn, "/__tool/spaces")
  defp started(conn, {:error, :busy}), do: redirect_to(conn, "/__tool/mirror")
  defp started(conn, {:error, :no_worker}), do: redirect_to(conn, "/__tool/mirror")
  defp started(conn, {:error, :nothing_to_do}), do: redirect_to(conn, "/__tool/spaces")

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

  # `open` on macOS, `xdg-open` on Linux, `explorer` on Windows — the tool's own
  # machine and a folder it already owns. The folder is created first, because an
  # empty workspace is still a folder a person may want to look at (and the one
  # they delete to start over). A failure is reported, not raised: a missing file
  # manager is not a reason to take the screen down.
  defp reveal(path) do
    with :ok <- Settings.ensure_root() do
      case System.cmd(file_manager(), [path], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, code} ->
          {:error, "the folder could not be opened (exit #{code}): #{String.trim(output)}"}
      end
    end
  end

  defp file_manager do
    case :os.type() do
      {:win32, _} -> "explorer"
      {:unix, :darwin} -> "open"
      {:unix, _} -> "xdg-open"
    end
  end
end
