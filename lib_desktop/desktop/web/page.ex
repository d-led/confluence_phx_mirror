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
  alias ConfluencePhxMirror.Sites

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

    # Whether a token is already stored for *this* site decides whether the field
    # is required, and nothing else. The stored value is never rendered: a secret
    # in a page's HTML is a secret in a screenshot, a cache and every extension
    # with a content script — and, worse, a token the browser would carry into
    # whatever address is typed next. Blank means "keep this site's token", and
    # a changed site has no token to keep.
    {secret_required, secret_hint} =
      case Settings.secret() do
        {:ok, _secret} ->
          {"", "A token is stored for this site. Leave this empty to keep it, or type a new one."}

        {:error, _none} ->
          {" required",
           "Stored in this machine's credential store, never in a file. A token belongs to the site named above."}
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
      <form method="post" action="/__tool/setup" autocomplete="off">
        <label>
          <span>Site URL</span>
          <input name="site" type="text" required placeholder="acme.atlassian.net"
                 inputmode="url" autocapitalize="off" spellcheck="false"
                 value="#{site}" autofocus>
          <small>Leave the <code>https://</code> off if you like — it is assumed.</small>
        </label>
        <label>
          <span>Account e-mail</span>
          <input name="email" type="email" placeholder="you@acme.com" value="#{email}">
          <small>Leave blank for a Server/Data Center personal access token.</small>
        </label>
        <label>
          <span>API token</span>
          <input name="secret" type="password" value=""#{secret_required} autocomplete="off">
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
      # The first run is one question and gets the whole window; coming back to
      # change the connection is a place you are in, and a window has no back
      # button, so that one keeps the sidebar.
      nav: not Settings.first_run?(),
      current: "/__tool/setup"
    )
  end

  @doc "The tool's home: what this workspace is, and what to do next."
  @spec home() :: String.t()
  def home do
    case Settings.readiness() do
      :ready ->
        document(
          "Confluence mirror export",
          """
          <h1>Ready</h1>
          #{site_warning()}
          <p class="lede">This workspace mirrors <strong>#{escape(Settings.site() || "")}</strong>.</p>
          <dl>
            <dt>Folder</dt><dd>#{escape(Settings.root())}</dd>
            <dt>Attachments</dt><dd>#{escape(Settings.blobs())}</dd>
          </dl>
          #{workspace_actions()}
          <p class="note">Next: <a href="/__tool/spaces">choose the spaces to mirror</a>.</p>
          """,
          current: "/__tool"
        )

      {:needs, missing} ->
        document(
          "Confluence mirror export",
          """
          <h1>Not connected yet</h1>
          #{site_warning()}
          <p class="lede">Everything works on what is in the folder below — mirroring
          is what needs a site and a token.</p>
          <p class="error" role="status">Still needed: #{Enum.map_join(missing, ", ", &Atom.to_string/1)}</p>
          <dl>
            <dt>Folder</dt><dd>#{escape(Settings.root())}</dd>
          </dl>
          #{workspace_actions()}
          <p class="note">Next: <a href="/__tool/setup">connect to Confluence</a>.</p>
          """,
          current: "/__tool"
        )
    end
  end

  # A folder that belongs to one site and an app set up for another is what a
  # lost settings file looks like. It is not a reason to die — reads are safe,
  # because nothing is written — but it is not something to leave unsaid either:
  # the tool would show the folder's content under the wrong name and refuse
  # every sync for a reason the person cannot guess.
  defp site_warning do
    case Sites.conflict() do
      nil ->
        ""

      %{recorded: recorded, recorded_url: url, configured: configured} ->
        """
        <div class="error" role="alert">
          <strong>This folder belongs to #{escape(recorded)}#{address(url)}, but the
          tool is set up for #{escape(configured)}.</strong>
          Reading works; mirroring is refused until the two agree, because one
          catalogue cannot hold two sites. Set the connection up for
          #{escape(recorded)} below, or start over in a folder of its own.
        </div>
        """
    end
  end

  defp address(nil), do: ""
  defp address(url), do: " (#{escape(url)})"

  @doc """
  Said when the folder could not be opened, with the reason the system gave.

  A screen that says nothing after a button is a button that looks broken, and
  the folder is the one thing here a person is expected to handle themselves.
  """
  @spec folder_problem(String.t()) :: String.t()
  def folder_problem(reason) do
    document("Confluence mirror export", """
    <h1>The folder could not be opened</h1>
    <p class="error" role="status">#{escape(reason)}</p>
    <p><a href="/__tool">Back</a></p>
    """)
  end

  # The folder is the tool's own state, and Finder is where a person handles it:
  # deleting it is how somebody starts over, and a delete button in here would be
  # one click away from an empty mirror with no undo. Opening the folder leaves
  # the decision where it can be seen.
  defp workspace_actions do
    """
    <form method="post" action="/__tool/open-folder" class="inline">
      <button type="submit">Show the folder in #{file_manager()}</button>
    </form>
    <p class="hint">To start over, quit the app and delete that folder; the next launch
    makes a new one.</p>
    """
  end

  defp file_manager do
    case :os.type() do
      {:win32, _} -> "File Explorer"
      {:unix, :darwin} -> "Finder"
      {:unix, _} -> "the file manager"
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
  button is a choice between "mirror" and "mirror again" rather than a guess,
  and a space the catalogue holds gets a second one: **Forget**, which stops
  mirroring it and moves what is here to the trash. The two questions are not the
  same — the site listing does not say what this catalogue keeps — so `:held`
  comes from the catalogue, and a space it holds with no pages still gets the
  button.

  `loading: true` draws the same list with **every control disabled** and a note
  saying why. A refresh is one round trip, and a person who presses a button
  during it is pressing a button about a list that is being replaced underneath
  them — the tool mirrored a sample's two spaces that way once. Nothing is
  drawn at all when there is no list yet: `loading/1` is that screen.
  """
  @spec spaces([map()], %{String.t() => non_neg_integer()}, map()) :: String.t()
  def spaces(spaces, counts, meta \\ %{}) do
    matching = Map.get(meta, :matching, length(spaces))
    known = Map.get(meta, :known, matching)
    held = Map.get(meta, :held, MapSet.new())
    blocked = if Map.get(meta, :loading, false), do: " disabled", else: ""

    rows =
      Enum.map_join(spaces, "", fn space ->
        mirrored = Map.get(counts, space.key, 0)

        # A space that has been mirrored has pages in the catalogue, so the row
        # is also the way into them: `/spaces/:key` is the mirror's own screen,
        # over the rows this run wrote.
        read =
          if mirrored > 0 do
            ~s( <a class="read" href="/spaces/#{escape(space.key)}">Read</a>)
          else
            ""
          end

        forget =
          if MapSet.member?(held, space.key) do
            """
            <form method="post" action="/__tool/forget">
              <input type="hidden" name="space" value="#{escape(space.key)}">
              <button type="submit" class="secondary"#{blocked} title="Stops mirroring it; what is here goes to the trash">Forget</button>
            </form>
            """
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
          #{forget}
          <form method="post" action="/__tool/mirror">
            <input type="hidden" name="space" value="#{escape(space.key)}">
            <button type="submit" class="secondary"#{blocked}>#{if mirrored > 0, do: "Mirror again", else: "Mirror"}</button>
          </form>
        </li>
        """
      end)

    # The nuclear option belongs first: on a site with a hundred thousand
    # spaces it is the only thing most people want, and finding it at the bottom
    # of a list they cannot scroll is the whole complaint.
    everything =
      if matching > 0 do
        # A bulk run copies the spaces this workspace is configured for — all of
        # them when nothing is configured — so the button counts that, not the
        # listing. "Mirror all 143" over a setup made for one space is how a
        # catalogue came to hold a hundred spaces nobody asked for.
        configured = Map.get(meta, :configured, 0)
        noun = if configured > 0, do: "configured space", else: "space"

        """
        <form method="post" action="/__tool/mirror_all" class="everything">
          <input type="hidden" name="q" value="#{escape(Map.get(meta, :query, ""))}">
          <button type="submit"#{blocked}>Mirror <span data-count>#{if configured > 0, do: configured, else: matching}</span> <span data-noun>#{noun}</span></button>
          <small>#{if configured > 0, do: "The spaces you configured, one after another. Nothing is added to that set.", else: "One after another, in the order they are listed."}</small>
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
    document(
      "Spaces",
      """
      <h1>Spaces</h1>
      <p class="lede">#{spaces_lede(known, meta)}</p>
      #{status_banner(Map.get(meta, :run))}
      #{everything}
      <form method="get" action="/__tool/spaces" class="filter" role="search">
        <input name="q" type="search" value="#{escape(Map.get(meta, :query, ""))}"
               placeholder="Filter by name or key" data-filter autofocus>
      </form>
      <ul class="spaces">#{rows}</ul>
      #{truncated}
      <p class="note" data-empty #{if spaces != [], do: "hidden", else: ""}>Nothing matches that.</p>
      """,
      current: "/__tool/spaces",
      status: Map.get(meta, :status),
      script: true
    )
  end

  # Where the list came from is the list's own business, not the settings': a
  # screen that named the configured site while showing the bundled sample's two
  # spaces is what a person had to ask about.
  defp spaces_lede(known, %{where: :sample}),
    do: "#{known} spaces in the bundled sample — this tool is not reading a site yet."

  defp spaces_lede(known, _meta),
    do: "#{known} spaces on #{escape(Settings.site() || "Confluence")}."

  @doc """
  Said when the tool cannot act: what is wrong, and the one screen that fixes it.

  The controls are left out rather than drawn disabled — a button that cannot
  work is a button that teaches people the tool is broken — and the sidebar
  stays, because the way out of a blocked state is navigation rather than an
  action.
  """
  @spec blocked(String.t()) :: String.t()
  def blocked(reason) do
    document(
      "Not yet",
      """
      <h1>Not yet</h1>
      <p class="lede">#{escape(reason)}</p>
      <p><a href="/__tool/setup">Open the connection</a></p>
      """,
      current: "/__tool/spaces"
    )
  end

  @doc "How the mirror is doing, in the words the run itself reports."
  @spec mirror(map()) :: String.t()
  def mirror(%{state: :running} = status) do
    document(
      "Mirroring #{status.label}",
      """
      <h1>Mirroring #{escape(status.label)}</h1>
      <p class="lede">#{status.done} pages read#{waiting(status)}</p>
      <p class="note">This page follows the run itself, not a guess at it.</p>
      #{cancel_form()}
      """,
      current: "/__tool/mirror",
      refresh: true
    )
  end

  def mirror(%{state: :queued} = status) do
    document(
      "Waiting to mirror #{status.label}",
      """
      <h1>Next in line</h1>
      <p class="lede">#{waiting(status) |> String.trim_leading(" · ")}</p>
      <p class="note">The run starts as soon as the one in front of it finishes.</p>
      #{cancel_form()}
      """,
      current: "/__tool/mirror",
      refresh: true
    )
  end

  def mirror(%{state: :done} = status) do
    document(
      "Mirrored #{status.label}",
      """
      <h1>Done</h1>
      <p class="lede">#{escape(status.label)} is in the catalogue — #{status.done} pages read.</p>
      <p class="note">The pages are read in the mirror itself.</p>
      <p><a href="/">Read what was mirrored</a></p>
      """,
      current: "/__tool/mirror"
    )
  end

  def mirror(%{state: :cancelled} = status) do
    document(
      "Mirror stopped",
      """
      <h1>Stopped</h1>
      <p class="lede">#{escape(status.label || "The run")} was cancelled after #{status.done} pages.</p>
      <p class="note">What was read before the stop is in the catalogue and stays there.</p>
      <p><a href="/__tool/spaces">Back to spaces</a></p>
      """,
      current: "/__tool/mirror"
    )
  end

  def mirror(%{state: :error} = status) do
    document(
      "Mirror stopped",
      """
      <h1>Mirror stopped</h1>
      <p class="lede">#{escape(status.label || "The run")} could not be finished.</p>
      <p class="error" role="alert">#{escape(describe_error(status.error))}</p>
      <p><a href="/__tool/spaces">Back to spaces</a></p>
      """,
      current: "/__tool/mirror"
    )
  end

  def mirror(_status) do
    document(
      "Nothing running",
      """
      <h1>Nothing is running</h1>
      <p><a href="/__tool/spaces">Choose a space</a></p>
      """,
      current: "/__tool/mirror"
    )
  end

  # Cancel is a plain form: it posts, the run stops at its next page, and the
  # page that comes back says what the run says. No script decides this.
  defp cancel_form do
    """
    <form method="post" action="/__tool/cancel">
      <button type="submit" class="secondary">Stop mirroring</button>
    </form>
    """
  end

  defp waiting(%{queued: 0}), do: ""
  defp waiting(%{queued: queued}), do: " · #{queued} more waiting"

  @doc """
  An error term as the sentence the runtime already had.

  The screen printed `inspect/1`, which is how a mirror that died reported
  `error {"MFS", %Exqlite.Error{…}}` — true, and no use to anybody standing in
  front of a window with no console. Anything raised carries its own message; the
  tuples this tool passes around are unwrapped to reach it; a shape nobody
  anticipated still says something.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(%{__exception__: true} = error), do: Exception.message(error)

  def describe_error({%{__exception__: true} = error, _stacktrace}),
    do: Exception.message(error)

  def describe_error({tag, reason}) when tag in [:error, :exit], do: describe_error(reason)

  def describe_error({:unknown_space, key}) when is_binary(key),
    do: "the site has no space called #{key}"

  # A personal space is a request the sync deliberately refuses by default — see
  # `Sync.personal_spaces?/0`. Said here rather than as "no such space", because
  # the space exists and the answer is a decision.
  def describe_error({:personal_space, key}) when is_binary(key),
    do:
      "#{key} is somebody's personal space, and this mirror does not take one unless it is configured to (CM_SYNC_PERSONAL_SPACES=true)."

  # A start while the space list is being fetched has no key to act on yet. The
  # buttons are drawn disabled in that window; this is the answer for a tab that
  # was rendered before the fetch began.
  def describe_error(:list_loading),
    do:
      "the space list is still being fetched. Nothing was started — press again once it is here."

  def describe_error({space_key, reason}) when is_binary(space_key),
    do: "in #{space_key}: #{describe_error(reason)}"

  def describe_error(reason) when is_binary(reason), do: reason
  def describe_error(reason), do: inspect(reason)

  @doc """
  The archive screen: what is in hand, what is being built, and the press.

  A build takes minutes on a large catalogue, so the page follows it rather than
  blocking on it — the same bargain the mirror screen makes. Nothing here counts
  pages: the builder knows how many bytes are on disk, and that is what it says.
  """
  @spec export(:absent | {:building, map()} | {:ready, map()}, Path.t()) :: String.t()
  def export(:absent, _path) do
    document(
      "Export",
      """
      <h1>No copy yet</h1>
      <p class="lede">A copy is every space in this catalogue as HTML, Markdown and
      attachments — a folder that opens without this tool.</p>
      <form method="post" action="/__tool/export">
        <button type="submit">Build the archive</button>
      </form>
      """,
      current: "/__tool/export"
    )
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
      current: "/__tool/export",
      refresh: true
    )
  end

  def export({:ready, %{bytes: bytes, at: at}}, path) do
    document(
      "Ready",
      """
      <h1>Ready</h1>
      <p class="lede">#{size(bytes)}, built #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}.</p>
      <p><a href="/__tool/export/site.zip" download>Download the archive</a></p>
      <p class="status">It is also on disk: <code>#{escape(path)}</code></p>
      <form method="post" action="/__tool/export">
        <button type="submit">Build it again</button>
      </form>
      """,
      current: "/__tool/export"
    )
  end

  @doc """
  The mirror screen after a run: the copy this tool wrote is read in the
  mirror's own pages, so there is nothing here to rebuild.
  """
  @spec problem(term()) :: String.t()
  def problem(reason) do
    document("Confluence could not be reached", """
    <h1>Confluence could not be reached</h1>
    <p class="lede">#{escape(Settings.site() || "The site")} did not answer.</p>
    <p class="error" role="alert">#{escape(inspect(reason))}</p>
    <p><a href="/__tool/spaces">Try again</a></p>
    """)
  end

  @doc """
  A start the tool refuses, in the words the reason needs.

  Not a redirect: a press that lands on a screen about some other run is a press
  that appears to have done nothing, which is the failure this whole page exists
  to avoid.
  """
  @spec refused(term()) :: String.t()
  def refused(reason) do
    document(
      "Not started",
      """
      <h1>Not started</h1>
      <p class="lede">#{escape(describe_error(reason))}</p>
      <p><a href="/__tool/spaces">Choose a space</a></p>
      """,
      current: "/__tool/spaces"
    )
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
    <div class="run" data-run data-status-url="/__tool/status">
      <span class="dot" aria-hidden="true"></span>
      <span data-run-text>#{escape(run_text(status))}</span>
      <a href="/__tool/mirror">details</a>
    </div>
    """
  end

  def status_banner(%{state: :queued} = status) do
    """
    <div class="run" data-run data-status-url="/__tool/status">
      <span class="dot" aria-hidden="true"></span>
      <span data-run-text>#{escape(run_text(status))}</span>
      <a href="/__tool/mirror">details</a>
    </div>
    """
  end

  def status_banner(%{state: :error} = status) do
    """
    <div class="run error">
      <span data-run-text>Stopped: #{escape(status.label || "the run")}</span>
      <a href="/__tool/mirror">details</a>
    </div>
    """
  end

  def status_banner(_status), do: ""

  defp run_text(%{state: :queued} = status),
    do: "Waiting to mirror #{status.label}#{waiting(status)}"

  defp run_text(status),
    do: "Mirroring #{status.label} · #{status.done} pages read#{waiting(status)}"

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

      function waitingText(status) {
        return status.queued > 0 ? " · " + status.queued + " more waiting" : "";
      }

      function poll() {
        if (finished) return;

        fetch(banner.getAttribute("data-status-url"), { headers: { accept: "application/json" } })
          .then(function (response) { return response.json(); })
          .then(function (status) {
            if (!text) return;

            if (status.state === "running") {
              text.textContent = "Mirroring " + status.label + " · " + status.done +
                " pages read" + waitingText(status);
            } else if (status.state === "queued") {
              text.textContent = "Waiting to mirror " + status.label + waitingText(status);
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
        :root { color-scheme: light dark; --accent: #2f5fe0; --line: rgba(127,127,127,.25); }
        * { box-sizing: border-box; }
        body {
          margin: 0; min-height: 100vh;
          display: grid; grid-template-columns: 15rem minmax(0, 1fr);
          font: 16px/1.5 ui-sans-serif, -apple-system, "Segoe UI", Roboto, sans-serif;
          background: Canvas; color: CanvasText;
        }
        /* The first-run form is one question, so it gets the whole window and
           no way out of itself. Every other screen is a place you work in. */
        body.plain { display: block; padding: 2rem 1rem; }
        body.plain main { max-width: 27rem; margin: 0 auto; }
        .sidebar {
          position: sticky; top: 0; align-self: start;
          height: 100vh; overflow-y: auto;
          padding: 1.25rem 1rem 2rem;
          border-right: 1px solid var(--line);
          font-size: .875rem;
        }
        .brand { font-weight: 700; letter-spacing: -0.01em; }
        .where {
          margin: .15rem 0 1.5rem; font-size: .75rem; opacity: .55;
          overflow-wrap: anywhere;
        }
        .section { margin: 0 0 1.35rem; }
        .section > span {
          display: block; margin: 0 0 .35rem; font-size: .6875rem;
          text-transform: uppercase; letter-spacing: .07em; opacity: .5;
        }
        .sidebar a {
          display: block; margin: 0 -.5rem; padding: .35rem .5rem;
          border-radius: .375rem; color: inherit; text-decoration: none;
          opacity: .78; transition: background .12s ease, opacity .12s ease;
        }
        .sidebar a:hover { background: rgba(127,127,127,.13); opacity: 1; }
        .sidebar a[aria-current="page"] {
          background: rgba(47,95,224,.12); color: var(--accent);
          opacity: 1; font-weight: 600;
        }
        main { padding: 2.25rem clamp(1rem, 4vw, 3rem); max-width: 54rem; }
        @media (max-width: 720px) {
          body { grid-template-columns: 1fr; }
          .sidebar {
            position: sticky; height: auto; border-right: 0;
            border-bottom: 1px solid var(--line); padding-bottom: 1rem;
          }
          .where { margin-bottom: .75rem; }
          .section { display: inline-block; margin: 0 .9rem .3rem 0; }
          .section > span { display: inline; margin-right: .35rem; }
          .sidebar a { display: inline-block; margin: 0 .2rem .2rem 0; }
          main { padding: 1.5rem 1rem; }
        }
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
          outline: none; border-color: var(--accent);
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
        a { color: var(--accent); }
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
    <body#{if opts[:nav] == false, do: ~s( class="plain"), else: ""}>
    #{if opts[:nav] == false, do: "", else: sidebar(opts[:current])}<main>#{body}
    #{if opts[:status], do: ~s(<p class="status">#{escape(opts[:status])}</p>), else: ""}
    </main>
    #{if opts[:script], do: ~s(<script defer src="/__tool/assets/app.js"></script>), else: ""}
    </body>
    </html>
    """
  end

  defp escape(value) when is_binary(value), do: Plug.HTML.html_escape(value) |> to_string()

  # The bar that stays put. A window with no address bar has only the links it
  # renders, and a row of them above the content vanishes as soon as the content
  # scrolls — which is what a person scrolling two hundred spaces found. So the
  # destinations live in a sidebar that does not move, the screen you are on is
  # marked, and the workspace it belongs to is named at the top.
  defp sidebar(current) do
    """
    <aside class="sidebar">
      <div class="brand">Confluence export</div>
      <div class="where">#{escape(Settings.site() || "not connected to a site yet")}</div>

      <div class="section">
        <span>This tool</span>
        #{entry("/__tool", "Set up", current)}
        #{entry("/__tool/setup", "Connection", current)}
      </div>

      <div class="section">
        <span>Mirror</span>
        #{entry("/__tool/spaces", "Spaces", current)}
        #{entry("/__tool/mirror", "Runs", current)}
        #{entry("/__tool/export", "Export", current)}
      </div>

      <div class="section">
        <span>Read</span>
        #{entry("/", "The mirror", current)}
        #{entry("/admin", "Administration", current)}
      </div>
    </aside>
    """
  end

  defp entry(href, label, href) do
    ~s(<a href="#{href}" aria-current="page">#{label}</a>)
  end

  defp entry(href, label, _current), do: ~s(<a href="#{href}">#{label}</a>)

  # Bytes as a person reads them. Kilobyte and megabyte because that is what a
  # browser's download shelf says, so the two agree.
  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes) when bytes < 1024 * 1024, do: "#{round(bytes / 1024)} kB"
  defp size(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"
end
