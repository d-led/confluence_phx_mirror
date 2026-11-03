defmodule ConfluencePhxMirror.Desktop.Web.Page do
  @moduledoc """
  The two documents the tool serves: the form a first run shows, and the stand-in
  for the main screen until there is a mirror to show.

  They are strings rather than templates because there are two of them and they
  share nothing: a template engine would be a dependency and a directory for
  about sixty lines of markup. The stylesheet is inline for the same reason —
  the sidecar serves loopback to a webview, so there is no cache to warm and no
  round trip to save.
  """

  alias ConfluencePhxMirror.Desktop.Settings

  @doc """
  The configuration form.

  `assigns` may carry `:site` and `:email` to keep what was typed, and `:error`
  to say why the last submission was not accepted — a form that clears itself
  and says nothing is the one thing a first run must not do.
  """
  @spec setup(map()) :: String.t()
  def setup(assigns \\ %{}) do
    # What is already known is already filled in: what this workspace recorded,
    # and — on a machine that was provisioned rather than set up — what the
    # environment suggests. Filling the field is all a suggestion does; the form
    # still has to be saved for the tool to use it.
    site = escape(assigns[:site] || Settings.site() || Settings.suggested_site() || "")
    email = escape(assigns[:email] || Settings.email() || Settings.suggested_email() || "")
    folder = escape(assigns[:root] || Settings.root() || "")

    # The token is filled in from whatever this machine already has — the
    # credential store's, or `CM_ATL_TOKEN`'s — because a rotated token has to be
    # replaced here and a field you cannot see is a field you cannot correct.
    # It is a password input on a loopback page, which is the trade this tool
    # makes: one reader, one machine, and no secret typed twice.
    {secret_required, secret_hint, existing} =
      case Settings.secret() do
        {:ok, secret} ->
          {"", "A token is stored here. Leave it, or replace it.", escape(secret)}

        {:error, _none} ->
          {" required", "Stored in this machine's credential store, never in a file.", ""}
      end

    error =
      case assigns[:error] do
        nil -> ""
        message -> ~s(<p class="error" role="alert">#{escape(message)}</p>)
      end

    document(
      "Set up the mirror",
      """
      <h1>Connect to Confluence</h1>
      <p class="lede">
        The tool keeps a copy of the pages you choose in a folder on this machine.
        Nothing is sent anywhere except the site you name here.
      </p>
      #{error}
      <form method="post" action="/setup" autocomplete="off">
        <label>
          <span>Site URL</span>
          <input name="site" type="url" required placeholder="https://acme.atlassian.net"
                 value="#{site}" autofocus>
        </label>
        <label>
          <span>Account e-mail</span>
          <input name="email" type="email" placeholder="you@acme.com" value="#{email}">
          <small>Leave blank for a Server/Data Center personal access token.</small>
        </label>
        <label>
          <span>API token</span>
          <input name="secret" type="password" value="#{existing}"#{secret_required}>
          <small>#{secret_hint}</small>
        </label>
        <label>
          <span>Folder</span>
          <input name="root" type="text" value="#{folder}" spellcheck="false">
          <small>Where the catalogue, the attachments and the pages are kept.</small>
        </label>
        <button type="submit">Save and continue</button>
      </form>
      """,
      nav: false
    )
  end

  @doc "The screen the window opens on: what this workspace is, and what to do next."
  @spec home() :: String.t()
  def home do
    case Settings.readiness() do
      :ready ->
        document("Confluence mirror export", """
        <h1>Ready</h1>
        <p class="lede">This workspace mirrors <strong>#{escape(Settings.site() || "")}</strong>.</p>
        <dl>
          <dt>Folder</dt><dd>#{escape(Settings.root())}</dd>
          <dt>Attachments</dt><dd>#{escape(Settings.blobs())}</dd>
        </dl>
        <p><a href="/spaces">Choose spaces to mirror</a></p>
        <p><a href="/site">Read the mirror</a></p>
        <p><a href="/export">Export a copy</a></p>
        <p><a href="/setup">Change the connection</a></p>
        """)

      {:needs, missing} ->
        document("Confluence mirror export", """
        <h1>Not connected yet</h1>
        <p class="lede">Everything works on what is in the folder below — mirroring
        is what needs a site and a token.</p>
        <p class="error" role="status">Still needed: #{Enum.map_join(missing, ", ", &Atom.to_string/1)}</p>
        <p><a href="/setup">Connect to Confluence</a></p>
        <p><a href="/site">Read what is already mirrored</a></p>
        <p><a href="/export">Export a copy</a></p>
        <dl>
          <dt>Folder</dt><dd>#{escape(Settings.root())}</dd>
        </dl>
        """)
    end
  end

  @doc """
  A screen shown while something is being fetched.

  A blank window with a spinner and no words is its own kind of panic, so this
  says what is being fetched, from where, and that nothing was lost. The page
  checks again itself; there is nothing for a person to press.
  """
  @spec loading(String.t()) :: String.t()
  def loading(message) do
    document(
      "Loading…",
      """
      <div class="spinner" role="status" aria-label="Loading"></div>
      <h1>Still fetching</h1>
      <p class="lede">#{escape(message)}</p>
      <p class="status">This page checks again every second. Nothing is lost if it takes a while.</p>
      """,
      refresh: true
    )
  end

  @doc """
  The spaces the source offers, with what the catalogue already holds.

  A space that has been mirrored before says how many pages it has, so the
  button is a choice between "mirror" and "mirror again" rather than a guess.
  """
  @spec spaces([map()], %{String.t() => non_neg_integer()}, map()) :: String.t()
  def spaces(spaces, counts, meta \\ %{}) do
    matching = Map.get(meta, :matching, length(spaces))
    known = Map.get(meta, :known, matching)

    rows =
      Enum.map_join(spaces, "", fn space ->
        mirrored = Map.get(counts, space.key, 0)

        # A space that has been mirrored has pages on disk, so the row is also
        # the way into them: `/site` serves the published copy, which is the
        # last finished one — readable while the next is being fetched.
        read =
          if mirrored > 0 do
            ~s( <a class="read" href="/site/spaces/#{escape(space.key)}/index.html">Read</a>)
          else
            ""
          end

        """
        <li data-search="#{escape(String.downcase(space.name))} #{escape(String.downcase(space.key))}">
          <div>
            <strong>#{escape(space.name)}</strong>
            <small>#{escape(space.key)}#{if mirrored > 0, do: " · #{mirrored} pages mirrored", else: " · not mirrored yet"}</small>
          </div>
          #{read}
          <form method="post" action="/mirror">
            <input type="hidden" name="space" value="#{escape(space.key)}">
            <button type="submit" class="secondary">#{if mirrored > 0, do: "Mirror again", else: "Mirror"}</button>
          </form>
        </li>
        """
      end)

    # The nuclear option belongs first: on a site with a hundred thousand
    # spaces it is the only thing most people want, and finding it at the bottom
    # of a list they cannot scroll is the whole complaint.
    everything =
      if matching > 0 do
        """
        <form method="post" action="/mirror_all" class="everything">
          <input type="hidden" name="q" value="#{escape(Map.get(meta, :query, ""))}">
          <button type="submit">Mirror all <span data-count>#{matching}</span> <span data-noun>spaces</span></button>
          <small>One after another, in the order they are listed.</small>
        </form>
        """
      else
        ""
      end

    truncated =
      if matching > length(spaces) do
        """
        <p class="note">
          Showing #{length(spaces)} of #{matching}. Narrow the filter to reach the rest.
        </p>
        """
      else
        ""
      end

    # The empty note is rendered by the server too, so the answer survives with
    # JavaScript off; the script only unhides it as you type.
    # The way out goes at the top. A window with no address bar has only the
    # links it renders, and one at the end of two hundred spaces is not a link.
    document(
      "Spaces",
      """
      <nav class="top"><a href="/">Home</a></nav>
      <h1>Spaces</h1>
      <p class="lede">#{known} spaces on #{escape(Settings.site() || "Confluence")}.</p>
      #{status_banner(Map.get(meta, :run))}
      #{everything}
      <form method="get" action="/spaces" class="filter" role="search">
        <input name="q" type="search" value="#{escape(Map.get(meta, :query, ""))}"
               placeholder="Filter by name or key" data-filter autofocus>
      </form>
      <ul class="spaces">#{rows}</ul>
      #{truncated}
      <p class="note" data-empty #{if spaces != [], do: "hidden", else: ""}>Nothing matches that.</p>
      """,
      status: Map.get(meta, :status),
      script: true
    )
  end

  @doc "How the mirror is doing, in the words the run itself reports."
  @spec mirror(map()) :: String.t()
  def mirror(%{state: :running} = status) do
    across =
      if status.count > 1, do: " · space #{status.index} of #{status.count}", else: ""

    document(
      "Mirroring #{status.label}",
      """
      <h1>Mirroring #{escape(status.label)}#{escape(across)}</h1>
      <p class="lede">#{status.done} of #{status.total} pages in this space</p>
      <p class="note">This page follows the run; it is not a progress bar that
      guesses.</p>
      """,
      refresh: true
    )
  end

  def mirror(%{state: :done} = status) do
    document("Mirrored #{status.label}", """
    <h1>Done</h1>
    <p class="lede">#{escape(status.label)} #{if status.count > 1, do: "are", else: "is"} in the catalogue.</p>
    <p class="note">The pages are being written for reading.</p>
    <p><a href="/site">Read the mirror</a></p>
    <p><a href="/export">Export a copy</a></p>
    <p><a href="/spaces">Back to spaces</a></p>
    """)
  end

  def mirror(%{state: :error} = status) do
    document("Mirror stopped", """
    <h1>Mirror stopped</h1>
    <p class="lede">#{escape(status.label)} could not be finished.</p>
    <p class="error" role="alert">#{escape(inspect(status.error))}</p>
    <p><a href="/spaces">Back to spaces</a></p>
    """)
  end

  def mirror(_status) do
    document("Nothing running", """
    <h1>Nothing is running</h1>
    <p><a href="/spaces">Choose a space</a></p>
    """)
  end

  @doc """
  The archive screen: what is in hand, what is being built, and the press.

  A build takes minutes on a large catalogue, so the page follows it rather than
  blocking on it — the same bargain the mirror screen makes. Nothing here counts
  pages: the builder knows how many bytes are on disk, and that is what it says.
  """
  @spec export(:absent | {:building, map()} | {:ready, map()}, Path.t()) :: String.t()
  def export(:absent, _path) do
    document("Export", """
    <h1>No copy yet</h1>
    <p class="lede">A copy is every space in this catalogue as HTML, Markdown and
    attachments — a folder that opens without this tool.</p>
    <form method="post" action="/export">
      <button type="submit">Build the archive</button>
    </form>
    <p><a href="/spaces">Back to the spaces</a></p>
    """)
  end

  def export({:building, %{bytes: bytes}}, _path) do
    document(
      "Preparing…",
      """
      <div class="spinner" role="status" aria-label="Preparing"></div>
      <h1>Preparing the archive</h1>
      <p class="lede">#{size(bytes)} written so far.</p>
      <p class="status">This page checks again every second. Nothing is lost if
      it takes a while.</p>
      """,
      refresh: true
    )
  end

  def export({:ready, %{bytes: bytes, at: at}}, path) do
    document("Ready", """
    <h1>Ready</h1>
    <p class="lede">#{size(bytes)}, built #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}.</p>
    <p><a href="/export/site.zip" download>Download the archive</a></p>
    <p class="status">It is also on disk: <code>#{escape(path)}</code></p>
    <form method="post" action="/export">
      <button type="submit">Build it again</button>
    </form>
    <p><a href="/">Back</a></p>
    """)
  end

  @doc """
  The mirror screen: the site itself, or what has to happen before there is one.

  The pages are served from a folder the exporter wrote, so this is the same
  HTML the archive holds — there is no second renderer to drift from it.
  """
  @spec site(:built | :building | :absent | {:error, String.t()}) :: String.t()
  def site(:built),
    do:
      document("Mirror", """
      <h1>Read the mirror</h1>
      <p><a href="/site/index.html">Open the mirror</a></p>
      <form method="post" action="/site">
        <button type="submit">Rebuild the pages</button>
      </form>
      """)

  def site(:building) do
    document(
      "Preparing…",
      """
      <div class="spinner" role="status" aria-label="Preparing"></div>
      <h1>Preparing the mirror</h1>
      <p class="status">Writing the pages this catalogue holds. This page
      checks again every second.</p>
      """,
      refresh: true
    )
  end

  def site(:absent) do
    document("Mirror", """
    <h1>Nothing to read yet</h1>
    <p class="lede">The pages are written from what has been mirrored. Mirror a
    space first, or write the pages from what is already here.</p>
    <form method="post" action="/site">
      <button type="submit">Write the pages</button>
    </form>
    <p><a href="/spaces">Choose a space to mirror</a></p>
    """)
  end

  def site({:error, message}) do
    document("The pages could not be written", """
    <h1>The pages could not be written</h1>
    <p class="error" role="alert">#{escape(message)}</p>
    <p class="note">What was here before is untouched.</p>
    <form method="post" action="/site">
      <button type="submit">Try again</button>
    </form>
    <p><a href="/">Back</a></p>
    """)
  end

  @doc "A problem reaching the source."
  @spec problem(term()) :: String.t()
  def problem(reason) do
    document("Confluence could not be reached", """
    <h1>Confluence could not be reached</h1>
    <p class="lede">#{escape(Settings.site() || "The site")} did not answer.</p>
    <p class="error" role="alert">#{escape(inspect(reason))}</p>
    <p><a href="/spaces">Try again</a></p>
    """)
  end

  @doc """
  A line saying a run is going, for the screen that started it.

  The screen it leaves you on follows the run rather than blocking on it: a
  mirror of a large space is an hour of waiting, and an hour of somebody's
  attention is not a thing to take. The line updates itself by asking `/status`;
  when the run ends the page reloads once, so the counts change with it.
  """
  @spec status_banner(map() | nil) :: String.t()
  def status_banner(%{state: :running} = status) do
    """
    <div class="run" data-run data-status-url="/status">
      <span class="dot" aria-hidden="true"></span>
      <span data-run-text>#{escape(run_text(status))}</span>
      <a href="/mirror">details</a>
    </div>
    """
  end

  def status_banner(%{state: :error} = status) do
    """
    <div class="run error">
      <span data-run-text>Stopped: #{escape(status.label || "the run")}</span>
      <a href="/mirror">details</a>
    </div>
    """
  end

  def status_banner(_status), do: ""

  defp run_text(status) do
    across = if status.count > 1, do: " · space #{status.index} of #{status.count}", else: ""
    "Mirroring #{status.label}#{across} · #{status.done} of #{status.total} pages"
  end

  @doc """
  The one script the tool serves: the live filter, and the run banner's pulse.

  Served as a file rather than inlined, so there is one copy of it and the page
  can cache it. It does nothing the server does not already do — the same AND
  rule, the same status — it only does it without a round trip.
  """
  @spec script() :: String.t()
  def script do
    ~S"""
    (function () {
      "use strict";

      // Live filter: every typed word must appear, the same rule the server
      // applies on submit, so typing and pressing Enter agree.
      var input = document.querySelector("[data-filter]");
      var items = Array.prototype.slice.call(document.querySelectorAll("ul.spaces > li"));
      var empty = document.querySelector("[data-empty]");
      var counts = Array.prototype.slice.call(document.querySelectorAll("[data-count]"));
      var form = document.querySelector("form.everything");

      function applyFilter() {
        var words = input.value.toLowerCase().split(/\s+/).filter(Boolean);
        var shown = 0;

        items.forEach(function (item) {
          var haystack = item.getAttribute("data-search") || "";
          var match = words.every(function (word) {
            return haystack.indexOf(word) !== -1;
          });
          item.hidden = !match;
          if (match) shown++;
        });

        counts.forEach(function (count) { count.textContent = shown; });
        if (empty) empty.hidden = shown !== 0;
        if (form) form.hidden = shown === 0;
      }

      if (input && items.length) {
        input.addEventListener("input", applyFilter);
        applyFilter();
      }

      // The run banner. Polls while it exists, then reloads once so the
      // catalogue counts shown on this page are the ones that just changed.
      var banner = document.querySelector("[data-run]");
      if (!banner) return;

      var text = banner.querySelector("[data-run-text]");
      var finished = false;

      function poll() {
        if (finished) return;

        fetch(banner.getAttribute("data-status-url"), { headers: { accept: "application/json" } })
          .then(function (response) { return response.json(); })
          .then(function (status) {
            if (!text) return;

            if (status.state === "running") {
              var across = status.count > 1 ? " · space " + status.index + " of " + status.count : "";
              text.textContent = "Mirroring " + status.label + across + " · " + status.done + " of " + status.total + " pages";
            } else if (status.state === "done") {
              finished = true;
              text.textContent = "Finished " + status.label;
              setTimeout(function () { window.location.reload(); }, 800);
            } else if (status.state === "error") {
              finished = true;
              text.textContent = "Stopped: " + status.label;
            } else {
              finished = true;
              banner.remove();
            }
          })
          // A dropped poll keeps the last known text: saying "unknown" would be
          // worse than being a second out of date.
          .catch(function () {});
      }

      setInterval(poll, 2000);
    })();
    """
  end

  defp document(title, body, opts \\ []) do
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      #{if opts[:refresh], do: ~s(<meta http-equiv="refresh" content="1">), else: ""}
      <title>#{escape(title)}</title>
      <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
          margin: 0; min-height: 100vh; display: grid; place-items: center;
          padding: 2rem 1rem;
          font: 16px/1.5 ui-sans-serif, -apple-system, "Segoe UI", Roboto, sans-serif;
          background: Canvas; color: CanvasText;
        }
        main { width: 100%; max-width: 27rem; }
        .nav { display: flex; flex-wrap: wrap; gap: .75rem; margin: 0 0 1.5rem;
               font-size: .8125rem; }
        .nav a { color: inherit; opacity: .65; text-decoration: none; }
        .nav a:hover { opacity: 1; text-decoration: underline; }
        h1 { font-size: 1.5rem; font-weight: 600; letter-spacing: -0.01em; margin: 0 0 .5rem; }
        .lede { margin: 0 0 1.75rem; opacity: .75; }
        .note { opacity: .6; font-size: .875rem; }
        label { display: block; margin-bottom: 1.1rem; }
        label span { display: block; font-size: .8125rem; font-weight: 600; margin-bottom: .35rem; }
        input {
          width: 100%; padding: .6rem .7rem; font: inherit; color: inherit;
          background: Field; border: 1px solid rgba(127,127,127,.45); border-radius: .5rem;
          transition: border-color .15s ease, box-shadow .15s ease;
        }
        input:focus {
          outline: none; border-color: #4f7cff;
          box-shadow: 0 0 0 3px rgba(79,124,255,.25);
        }
        small { display: block; margin-top: .35rem; font-size: .75rem; opacity: .6; }
        button {
          width: 100%; padding: .65rem; font: inherit; font-weight: 600;
          color: #fff; background: #2f5fe0; border: 0; border-radius: .5rem;
          cursor: pointer; transition: background .15s ease, transform .05s ease;
        }
        button:hover { background: #2a54c8; }
        button:active { transform: translateY(1px); }
        .error {
          margin: 0 0 1.25rem; padding: .65rem .75rem; border-radius: .5rem;
          background: rgba(220,60,60,.12); border: 1px solid rgba(220,60,60,.35);
          font-size: .875rem;
        }
        dl { display: grid; grid-template-columns: auto 1fr; gap: .35rem 1rem;
             margin: 0 0 1.5rem; font-size: .875rem; }
        dt { font-weight: 600; }
        dd { margin: 0; opacity: .75; overflow-wrap: anywhere; }
        a { color: #2f5fe0; }
        nav.top { margin-bottom: 1rem; font-size: .8125rem; }
        nav.top a { text-decoration: none; opacity: .7; }
        nav.top a:hover { text-decoration: underline; opacity: 1; }
        ul.spaces { list-style: none; margin: 0 0 1.5rem; padding: 0; }
        ul.spaces li { display: flex; align-items: center; justify-content: space-between;
                       gap: 1rem; padding: .75rem 0; border-bottom: 1px solid rgba(127,127,127,.2); }
        ul.spaces li:first-child { border-top: 1px solid rgba(127,127,127,.2); }
        ul.spaces form { margin: 0; }
        button.secondary { width: auto; padding: .4rem .9rem; font-size: .8125rem;
                           background: transparent; color: #2f5fe0;
                           border: 1px solid rgba(47,95,224,.4); }
        button.secondary:hover { background: rgba(47,95,224,.08); }
        form.everything { margin: 0 0 1rem; }
        form.everything button { width: 100%; }
        form.everything small { display: block; margin-top: .4rem; text-align: center; }
        form.filter { margin: 0 0 1rem; }
        form.filter input { width: 100%; }
        .status { margin: 2rem 0 0; font-size: .8125rem; opacity: .5; }
        .spinner {
          width: 1.25rem; height: 1.25rem; margin: 0 0 1rem;
          border: 2px solid rgba(127,127,127,.3); border-top-color: #2f5fe0;
          border-radius: 50%; animation: spin .8s linear infinite;
        }
        @keyframes spin { to { transform: rotate(360deg); } }
        @media (prefers-reduced-motion: reduce) { .spinner { animation-duration: 3s; } }
      </style>
    </head>
    <body><main>#{if opts[:nav] == false, do: "", else: nav()}#{body}
    #{if opts[:status], do: ~s(<p class="status">#{escape(opts[:status])}</p>), else: ""}
    </main></body>
    </html>
    """
  end

  # Where "read the mirror" goes. `/site` decides: the pages themselves when
  # there is a copy, a build when there is something to build, and the reason
  # when there is neither — so a link here is never a dead end.
  defp escape(value) when is_binary(value), do: Plug.HTML.html_escape(value) |> to_string()

  # Every screen but the first-run form carries the same bar, because every
  # screen but that one can lead somewhere else: a page you cannot leave is how
  # a tool feels like a dead end.
  defp nav do
    """
    <nav class="nav">
      <a href="/">Home</a>
      <a href="/site">Mirror</a>
      <a href="/spaces">Spaces</a>
      <a href="/mirror">Runs</a>
      <a href="/export">Export</a>
      <a href="/setup">Connection</a>
    </nav>
    """
  end

  # Bytes as a person reads them. Kilobyte and megabyte because that is what a
  # browser's download shelf says, so the two agree.
  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes) when bytes < 1024 * 1024, do: "#{round(bytes / 1024)} kB"
  defp size(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"
end
