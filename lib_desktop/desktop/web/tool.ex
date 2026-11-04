defmodule ConfluencePhxMirror.Desktop.Web.Tool do
  @moduledoc """
  The tool's own screens, under `/__tool`: the connection, and the mirror run it
  queues.

  Everything a reader looks at is the mirror's own — the same LiveViews, the
  same admin area, at the same paths — and it is served by the endpoint mounted
  beside this router (see `ConfluencePhxMirror.Desktop.Web.Dispatch`). What is
  left here is what a single-user tool has and a deployment does not: where its
  site is and which token reaches it, and the one press that starts or stops the
  mirror touching its own catalogue.

  Starting a run is `Sync.enqueue/3` (`ConfluencePhxMirror.Desktop.Jobs`), on the
  queue this build already runs — so the press produces a job, the job a row in
  `sync_runs`, and the screen follows that row rather than a task in the web
  server. Stopping it is `Sync.cancel/2`, which the run honours at its next page.

  Everything is answered on loopback, for the webview the tool itself opened.
  There is no sign-in, because there is one reader and the window is the only
  way in — which is also why the token in the form is written straight to the
  OS credential store and never echoed back.
  """

  use Plug.Router

  alias ConfluencePhxMirror.Desktop.{Archive, Catalogue, Jobs, Settings, Spaces, Web.Page}
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Trash

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

    # A first run has nothing to read, so it continues to the one thing left to
    # do: choosing spaces. Landing it on the mirror showed an empty catalogue
    # under the demo's name — the machine had not mirrored anything yet.
    first_run = Settings.first_run?()

    case Settings.configure(attrs) do
      :ok ->
        conn
        |> put_resp_header("location", if(first_run, do: "/__tool/spaces", else: "/"))
        |> send_resp(303, "")

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

  # Forgetting a space is the one removal this tool offers: the key stops being
  # mirrored and what is already here goes to the trash, where the holding period
  # and the mirror's own trash screen still apply. Same act as removing the key
  # from the configured set in the admin area, with a button — a window has no
  # `/admin/spaces` to go to, and a catalogue it is no longer configured to keep
  # used to be something nobody could say anything about.
  post "/__tool/forget" do
    case Trash.forget(ConfluencePhxMirror.Audit.system_actor(), conn.params["space"] || "") do
      {:ok, _removed} ->
        conn |> put_resp_header("location", "/__tool/spaces") |> send_resp(303, "")

      {:error, reason} ->
        send_resp(conn, 400, Page.problem(reason))
    end
  end

  get "/__tool/spaces" do
    query = String.trim(conn.params["q"] || "")

    # A screen whose controls cannot work says so and stops, rather than listing
    # spaces that cannot be mirrored and leaving a person to find out by pressing
    # something. The sidebar still works: the way out of a blocked state is
    # another screen, and that is navigation rather than a control.
    case blocked() do
      nil -> list_spaces(conn, query)
      reason -> send_resp(conn, 200, Page.blocked(reason))
    end
  end

  defp list_spaces(conn, query) do
    case Spaces.list() do
      {:ok, spaces} ->
        matching = filter(spaces, query)
        status = Spaces.state()

        send_resp(
          conn,
          200,
          Page.spaces(Enum.take(matching, @page_size), Catalogue.page_counts(), %{
            query: query,
            known: length(spaces),
            matching: length(matching),
            # What this catalogue holds, which is not the same question as what
            # the site lists: a space here with no pages is still a space that
            # can be let go of.
            held: MapSet.new(ConfluencePhxMirror.Mirror.list_spaces(), & &1.key),
            configured: length(ConfluencePhxMirror.Sync.SpaceScope.added()),
            # A list being replaced underneath a person is not one to press a
            # button about: every control is drawn disabled until the answer
            # that matters is in hand.
            loading: status.refreshing?,
            status: if(status.refreshing?, do: "Asking the site for its space list again…"),
            run: Jobs.status()
          })
        )

      # Nothing is fetched in the request: no screen waits on Confluence, and a
      # slow site shows what is happening instead of a blank window — with no
      # list and no controls, because there is nothing yet to act on. The fetch
      # itself belongs to the boot, to a saved connection, or to the retry this
      # branch's failure case makes once — not to a page that reloads every
      # second, which asked an unreachable site again on every reload.
      :loading ->
        send_resp(
          conn,
          200,
          Page.loading("Asking #{Settings.site() || "the site"} for its spaces.")
        )

      # The failure is kept, so opening the screen again asks a second time rather
      # than showing yesterday's answer forever — which is what a fresh machine did,
      # having cached the "no token" failure from boot.
      {:error, reason} ->
        Spaces.refresh()
        send_resp(conn, 502, Page.problem(reason))
    end
  end

  # What stops this tool from working, in the words a person needs.
  defp blocked do
    cond do
      ConfluencePhxMirror.Sites.conflict() ->
        "This folder belongs to another site. Open the connection and set the tool up for that site."

      not Settings.configured?() ->
        "This tool is not connected to a site yet. Open the connection and name the site and a token."

      true ->
        nil
    end
  end

  # A run is started and then left alone: the screen it leaves you on follows
  # it, so a mirror that takes an hour does not take an hour of your attention.
  post "/__tool/mirror" do
    case blocked() do
      nil -> started(conn, Jobs.start_mirror([conn.params["space"]], conn.params["space"]))
      _reason -> redirect_to(conn, "/__tool/spaces")
    end
  end

  # The one control the run screen needs. A run stops at its next page, so the
  # answer is the run's row, not this request's: the screen reloads and says
  # what the run says.
  post "/__tool/cancel" do
    {:ok, _stopped} = Jobs.cancel()
    redirect_to(conn, "/__tool/mirror")
  end

  post "/__tool/mirror_all" do
    query = String.trim(conn.params["q"] || "")

    case {blocked(), Spaces.list()} do
      {is_blocked, _list} when is_binary(is_blocked) ->
        redirect_to(conn, "/__tool/spaces")

      {nil, {:ok, spaces}} ->
        configured = ConfluencePhxMirror.Sync.SpaceScope.added()
        keys = spaces |> filter(query) |> Enum.map(& &1.key) |> configured_only(configured)

        started(
          conn,
          Jobs.start_mirror(keys, bulk_label(keys, query, configured), remember: false)
        )

      # Still being fetched: send them back to the screen that shows it, rather
      # than mirroring a list that is not there yet.
      {nil, _loading_or_failed} ->
        redirect_to(conn, "/__tool/spaces")
    end
  end

  # A bulk run copies what this workspace is configured for. With nothing
  # configured that is every space the site lists; with a set, it is that set —
  # the button is "copy what I asked for", not "copy everything and rewrite what
  # I asked for", which is how a workspace configured for one space came to hold a
  # hundred it was never meant to.
  defp configured_only(keys, []), do: keys
  defp configured_only(keys, configured), do: Enum.filter(keys, &(&1 in configured))

  defp bulk_label(keys, query, configured) do
    count = length(keys)

    cond do
      query != "" -> "#{count} spaces matching #{inspect(query)}"
      configured == [] -> "all #{count} spaces"
      true -> "the #{count} configured space#{if count == 1, do: "", else: "s"}"
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
  defp started(conn, {:error, :nothing_to_do}), do: redirect_to(conn, "/__tool/spaces")

  # Anything else is the tool declining, and a refusal has to be readable where
  # the press happened: a redirect to the run screen would show whatever ran last.
  defp started(conn, {:error, reason}), do: send_resp(conn, 409, Page.refused(reason))

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

  defp explain(:secret_required),
    do:
      "A token is needed for this site. A token stored for one address is never sent to another."

  defp explain({:invalid_site, site}), do: "#{site} is not a URL this tool can use."

  defp explain({:secret_not_stored, reason}) do
    "The site and folder were saved, but the token could not be stored in this " <>
      "machine's keychain (#{inspect(reason)}). Unlock the login keychain and save " <>
      "the connection again."
  end

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
