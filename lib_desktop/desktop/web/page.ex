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
          #{way_forward("/__tool/spaces", "Choose spaces to mirror")}
          <dl>
            <dt>Folder</dt><dd>#{escape(Settings.root())}</dd>
            <dt>Attachments</dt><dd>#{escape(Settings.blobs())}</dd>
          </dl>
          #{workspace_actions()}
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
          #{way_forward("/__tool/setup", "Connect to Confluence")}
          <dl>
            <dt>Folder</dt><dd>#{escape(Settings.root())}</dd>
          </dl>
          #{workspace_actions()}
          """,
          current: "/__tool"
        )
    end
  end

  # The way forward is a button, and it is the only one: this screen used to lead
  # with "Show the folder in Finder", so the biggest thing on it opened a file
  # manager and the next step was a sentence with a link in it.
  defp way_forward(href, label) do
    ~s(<p class="actions"><a class="button primary" href="#{href}">#{label}</a></p>)
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
  # the decision where it can be seen — which is also why it is the quiet button.
  defp workspace_actions do
    """
    <form method="post" action="/__tool/open-folder" class="inline">
      <button type="submit" class="secondary">Show the folder in #{file_manager()}</button>
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
          <label class="pick">
            <input type="checkbox" name="space" value="#{escape(space.key)}" form="selection"#{blocked}>
            <span>
              <strong>#{escape(space.name)}</strong>
              <small>#{escape(space.key)}#{if mirrored > 0, do: " · #{mirrored} pages mirrored", else: " · not mirrored yet"}</small>
            </span>
          </label>
          #{read}
          #{forget}
        </li>
        """
      end)

    # One button, whose meaning is the selection: tick nothing and it takes
    # everything the filter shows; tick anything and it takes exactly that. The
    # checkboxes carry `form="selection"` so they drive that one form from
    # inside the list, instead of a form per row and one press per space.
    #
    # The picker is drawn whether or not a run is going. It used to be drawn only
    # while the tool was idle, so a person who had just started one space's
    # mirror saw no way to choose another and no word about why — a screen that
    # says the choice is closed, which is the worst thing a control can say
    # silently. While a run is going the picker is a named region under the run's
    # own lead, and it says what pressing it does.
    running? = going?(Map.get(meta, :run))
    configured = Map.get(meta, :configured, 0)
    query = Map.get(meta, :query, "")

    action =
      if matching > 0 do
        lead = if running?, do: lead_actions(), else: ""
        lead <> choose(matching, configured, running?, blocked, query)
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
      #{if matching > 0, do: action, else: ""}
      <form method="get" action="/__tool/spaces" class="filter" role="search">
        <input name="q" type="search" value="#{escape(Map.get(meta, :query, ""))}"
               placeholder="Filter by name or key" data-filter autofocus>
      </form>
      <ul class="spaces">#{rows}</ul>
      <p class="note" data-empty #{if spaces != [], do: "hidden", else: ""}>Nothing matches that.</p>
      """,
      current: "/__tool/spaces",
      status: Map.get(meta, :status),
      script: true
    )
  end

  defp lead_actions do
    """
    <p class="actions">
      <a class="button primary" href="/">Continue to the mirror</a>
      <a class="button secondary" href="/__tool/mirror">Follow the run</a>
    </p>
    """
  end

  # The picker, and — while a run is going — the words that make it obvious what
  # happens next: this one goes quiet and queues, it does not replace or
  # interrupt anything. The heading is what a person skimming for "how do I add
  # another space" is looking for, so the region has one instead of being a bare
  # button under a note.
  defp choose(matching, configured, running?, blocked, query) do
    count = if configured > 0, do: configured, else: matching
    noun = count_noun(count, configured > 0)
    verb = if running?, do: "Queue", else: "Mirror"
    quiet = if running?, do: ~s( class="secondary"), else: ""

    heading =
      if running? do
        """
        <h2 id="choose-heading">Choose more spaces</h2>
        <p class="note">A run is going. What you choose here is added to the queue
        and starts when the current run ends — nothing that is running is
        interrupted.</p>
        """
      else
        ""
      end

    note = if running?, do: "", else: ~s(<p class="note">#{selection_note(configured)}</p>)

    """
    #{heading}
    <form method="post" action="/__tool/mirror" id="selection" class="everything"#{if running?, do: ~s( aria-labelledby="choose-heading"), else: ""}>
      <input type="hidden" name="q" value="#{escape(query)}">
      <button type="submit"#{quiet}#{blocked} data-mirror>#{verb} <span data-count>#{count}</span> <span data-noun>#{noun}</span></button>
      #{if running?, do: "", else: ~s(<a href="/__tool/mirror" class="next">Follow the run</a>)}
    </form>
    #{note}
    """
  end

  defp selection_note(configured) when configured > 0,
    do: "The spaces you configured, one after another. Nothing is added to that set."

  defp selection_note(_configured),
    do: "Tick nothing to take every space the filter shows, or tick the ones you want."

  # "Mirror 1 space", "Mirror 934 spaces": a count and its noun agree, which the
  # screen did not do while the number was the server's and the noun was a
  # constant.
  defp count_noun(1, false), do: "space"
  defp count_noun(_count, false), do: "spaces"
  defp count_noun(1, true), do: "configured space"
  defp count_noun(_count, true), do: "configured spaces"

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
      #{continue_actions("The run keeps going while you read.")}
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
      #{continue_actions("Whatever is mirrored already reads in the mirror.")}
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
      #{continue_actions("The pages are read in the mirror itself.")}
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
      #{continue_actions("What was read before the stop is in the catalogue and stays there.")}
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
      <p class="actions">
        <a class="button primary" href="/__tool/spaces">Choose spaces to try again</a>
        <a class="button secondary" href="/">Continue to the mirror</a>
      </p>
      """,
      current: "/__tool/mirror"
    )
  end

  def mirror(_status) do
    document(
      "Nothing running",
      """
      <h1>Nothing is running</h1>
      <p class="actions"><a class="button primary" href="/__tool/spaces">Choose a space</a></p>
      """,
      current: "/__tool/mirror"
    )
  end

  # The one action offered once a run exists: read what was mirrored. Beside it,
  # and quieter, the way back to choosing more — a person who has mirrored
  # something usually wants to look at it, and a person who wants more should not
  # have to find it in a sidebar.
  defp continue_actions(note) do
    """
    <p class="actions">
      <a class="button primary" href="/">Continue to the mirror</a>
      <a class="button secondary" href="/__tool/spaces">Choose more spaces</a>
    </p>
    <p class="note">#{escape(note)}</p>
    """
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

  # A run in flight owns the screen's action: pressing again would only queue
  # behind it, and a button that appears to work while nothing moves is worse
  # than a sentence saying where the run is.
  defp going?(%{state: state}) when state in [:running, :queued], do: true
  defp going?(_run), do: false

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
    </div>
    """
  end

  def status_banner(%{state: :queued} = status) do
    """
    <div class="run" data-run data-status-url="/__tool/status">
      <span class="dot" aria-hidden="true"></span>
      <span data-run-text>#{escape(run_text(status))}</span>
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
    do: "Mirroring #{status.label} · #{status.done} pages read#{calls(status)}#{waiting(status)}"

  # What the run has cost the site so far. Absent on a status read before the
  # run started, and on a source that makes no calls (the demo snapshot).
  defp calls(%{calls: calls}) when is_integer(calls) and calls > 0, do: " · #{calls} calls"
  defp calls(_status), do: ""

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
      var nouns = Array.prototype.slice.call(document.querySelectorAll("[data-noun]"));
      var boxes = Array.prototype.slice.call(document.querySelectorAll("input[type=checkbox][form=selection]"));
      var form = document.getElementById("selection");
      var shown = items.length;

      // The one button says what it will do: nothing ticked takes the list the
      // filter shows, anything ticked takes exactly that.
      function applyCount() {
        var ticked = boxes.filter(function (box) { return box.checked; }).length;
        var number = ticked > 0 ? ticked : shown;

        counts.forEach(function (count) { count.textContent = number; });
        nouns.forEach(function (noun) {
          if (ticked > 0) {
            noun.textContent = ticked === 1 ? "selected space" : "selected spaces";
          } else {
            noun.textContent = number === 1 ? "space" : "spaces";
          }
        });
      }

      function applyFilter() {
        var words = input.value.toLowerCase().split(/\s+/).filter(Boolean);
        shown = 0;

        items.forEach(function (item) {
          var haystack = item.getAttribute("data-search") || "";
          var match = words.every(function (word) {
            return haystack.indexOf(word) !== -1;
          });
          item.hidden = !match;
          if (match) shown++;
        });

        if (empty) empty.hidden = shown !== 0;
        if (form) form.hidden = shown === 0;
        applyCount();
      }

      if (input && items.length) {
        input.addEventListener("input", applyFilter);
        applyFilter();
      }

      boxes.forEach(function (box) { box.addEventListener("change", applyCount); });

      // The run banner. Polls while it exists, then reloads once so the
      // catalogue counts shown on this page are the ones that just changed.
      var banner = document.querySelector("[data-run]");
      if (!banner) return;

      var text = banner.querySelector("[data-run-text]");
      var finished = false;

      function waitingText(status) {
        return status.queued > 0 ? " · " + status.queued + " more waiting" : "";
      }

      function callsText(status) {
        return status.calls > 0 ? " · " + status.calls + " calls" : "";
      }

      function poll() {
        if (finished) return;

        fetch(banner.getAttribute("data-status-url"), { headers: { accept: "application/json" } })
          .then(function (response) { return response.json(); })
          .then(function (status) {
            if (!text) return;

            if (status.state === "running") {
              text.textContent = "Mirroring " + status.label + " · " + status.done +
                " pages read" + callsText(status) + waitingText(status);
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
        /* Typography first, because everything else is a decision on top of it.
           One system stack, a 16px base with a 1.6 line height, and a short scale
           (13 / 14 / 15 / 16 / 18 / 22 / 28px) so a screen has three sizes at
           most. Muted text is a colour with real contrast, never `opacity`: an
           opacity-muted label went to 3.4:1 in the light theme, which is the
           one thing a window read all day must not do. Prose stops at 66ch, and
           every number a person compares is tabular. */
        :root {
          color-scheme: light dark;
          --accent: #2f5fe0;
          --accent-ink: #fff;
          --accent-soft: rgba(47, 95, 224, .1);
          --line: rgba(127, 127, 127, .28);
          --muted: rgba(0, 0, 0, .68);
          --hover: rgba(127, 127, 127, .12);
          --danger: #b42318;
          --radius: .5rem;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --accent: #8aa8ff;
            --accent-ink: #10151f;
            --accent-soft: rgba(138, 168, 255, .16);
            --line: rgba(255, 255, 255, .18);
            --muted: rgba(255, 255, 255, .74);
            --hover: rgba(255, 255, 255, .08);
            --danger: #ff9b8f;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; min-height: 100vh;
          display: grid; grid-template-columns: 16rem minmax(0, 1fr);
          font: 400 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
          background: Canvas; color: CanvasText;
          -webkit-font-smoothing: antialiased;
          text-rendering: optimizeLegibility;
        }
        /* The first-run form is one question, so it gets the whole window and
           no way out of itself. Every other screen is a place you work in. */
        body.plain { display: block; padding: 3rem 1rem; }
        body.plain main { max-width: 26rem; margin: 0 auto; }
        .sidebar {
          position: sticky; top: 0; align-self: start;
          height: 100vh; overflow-y: auto;
          padding: 1.5rem 1rem 2rem;
          border-right: 1px solid var(--line);
          font-size: .9375rem;
        }
        .brand { font-size: 1rem; font-weight: 650; letter-spacing: -0.015em; }
        .where {
          margin: .25rem 0 1.75rem; font-size: .8125rem; color: var(--muted);
          overflow-wrap: anywhere;
        }
        .section { margin: 0 0 1.5rem; }
        .section > span {
          display: block; margin: 0 0 .4rem; padding: 0 .5rem;
          font-size: .6875rem; font-weight: 600; color: var(--muted);
          text-transform: uppercase; letter-spacing: .09em;
        }
        .sidebar a {
          display: flex; align-items: center; min-height: 2.25rem;
          margin: 0 -.25rem; padding: .35rem .5rem;
          border-radius: .375rem; color: inherit; text-decoration: none;
          transition: background .12s ease;
        }
        .sidebar a:hover { background: var(--hover); }
        .sidebar a[aria-current="page"] {
          background: var(--accent-soft); color: var(--accent); font-weight: 600;
        }
        .sidebar a:focus-visible, .button:focus-visible, a:focus-visible {
          outline: 2px solid var(--accent); outline-offset: 2px;
        }
        main {
          padding: 2.5rem clamp(1rem, 4vw, 3rem) 4rem;
          max-width: 60rem; width: 100%;
        }
        @media (max-width: 720px) {
          /* The nav row is as tall as its links and the rest of the window goes
             to the screen: stretching both rows left an empty band under the
             nav that read as a broken page. */
          body { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
          .sidebar {
            position: sticky; height: auto; border-right: 0;
            border-bottom: 1px solid var(--line); padding: 1rem 1rem .75rem;
          }
          .where { margin-bottom: .75rem; }
          .section { display: inline-block; margin: 0 1rem .25rem 0; }
          .section > span { display: inline; margin-right: .4rem; padding: 0; }
          .sidebar a { display: inline-flex; margin: 0 .15rem .15rem 0; }
          main { padding: 1.5rem 1rem 3rem; }
        }
        h1 {
          font-size: 1.75rem; line-height: 1.2; font-weight: 650;
          letter-spacing: -0.02em; margin: 0 0 .5rem;
        }
        /* A second level exists for the one screen that has two regions: what is
           running, and what to choose for the next one. It is a size down from
           h1 and a step up from body, so it reads as a heading without
           competing with the page's own title. */
        h2 {
          font-size: 1.125rem; line-height: 1.3; font-weight: 650;
          letter-spacing: -0.01em; margin: 1.75rem 0 .35rem;
        }
        .lede, .note, .hint, p { max-width: 66ch; }
        .lede { margin: 0 0 1.5rem; font-size: 1.0625rem; color: var(--muted); }
        .note { margin: .5rem 0 0; font-size: .9375rem; color: var(--muted); }
        .hint { margin: 1rem 0 0; font-size: .875rem; color: var(--muted); }
        label { display: block; margin-bottom: 1.25rem; }
        label span {
          display: block; margin-bottom: .35rem;
          font-size: .9375rem; font-weight: 600;
        }
        input {
          width: 100%; min-height: 2.5rem; padding: .5rem .7rem;
          font: inherit; color: inherit;
          background: Field; border: 1px solid var(--line); border-radius: var(--radius);
          transition: border-color .15s ease, box-shadow .15s ease;
        }
        input:focus {
          outline: none; border-color: var(--accent);
          box-shadow: 0 0 0 3px var(--accent-soft);
        }
        small { display: block; margin-top: .4rem; font-size: .875rem; color: var(--muted); }
        button {
          min-height: 2.5rem; padding: .5rem 1.1rem;
          font: inherit; font-weight: 600; color: var(--accent-ink);
          background: var(--accent); border: 0; border-radius: var(--radius);
          cursor: pointer; transition: filter .15s ease, transform .05s ease;
        }
        button:hover { filter: brightness(.94); }
        button:active { transform: translateY(1px); }
        button:disabled { opacity: .55; cursor: not-allowed; }
        body.plain button { width: 100%; }
        .error {
          margin: 0 0 1.5rem; padding: .7rem .85rem; border-radius: var(--radius);
          background: color-mix(in srgb, var(--danger) 10%, transparent);
          border: 1px solid color-mix(in srgb, var(--danger) 40%, transparent);
          color: var(--danger); font-size: .9375rem;
        }
        dl { display: grid; grid-template-columns: auto 1fr; gap: .4rem 1.25rem;
             margin: 0 0 1.75rem; font-size: .9375rem; }
        dt { font-weight: 600; }
        dd { margin: 0; color: var(--muted); overflow-wrap: anywhere; }
        a { color: var(--accent); text-underline-offset: 2px; }
        /* One prominent action per screen, and it is the way forward: the run's
           own screen and the spaces screen both lead into the mirror. A link
           styled like the others in the sidebar is not a lead. */
        .actions { display: flex; flex-wrap: wrap; align-items: center; gap: .6rem;
                   margin: 0 0 .75rem; }
        .button {
          display: inline-flex; align-items: center; justify-content: center;
          min-height: 2.5rem; padding: .5rem 1.1rem;
          font: inherit; font-weight: 600; border-radius: var(--radius);
          border: 1px solid transparent; text-decoration: none; cursor: pointer;
          transition: background .15s ease, border-color .15s ease, filter .15s ease;
        }
        .button.primary { background: var(--accent); color: var(--accent-ink); }
        .button.primary:hover { filter: brightness(.94); }
        .button.secondary {
          background: transparent; color: var(--accent);
          border-color: color-mix(in srgb, var(--accent) 45%, transparent);
        }
        .button.secondary:hover { background: var(--accent-soft); }
        button.secondary {
          min-height: 2.125rem; padding: .35rem .85rem; font-size: .875rem;
          background: transparent; color: var(--accent);
          border: 1px solid color-mix(in srgb, var(--accent) 45%, transparent);
        }
        button.secondary:hover { background: var(--accent-soft); }
        form.everything { margin: 0 0 .5rem; display: flex; align-items: center; gap: .75rem; }
        form.everything button { flex: 1; }
        /* While a run is going this button is the quiet one, so it does not
           stretch across the screen like the lead does. */
        form.everything button.secondary { flex: 0 0 auto; }
        form.inline { margin: 1.25rem 0 0; }
        form.inline button { min-height: 2.25rem; font-size: .9375rem; }
        a.next { font-size: .9375rem; white-space: nowrap; }
        form.filter { margin: 0 0 1rem; }
        form.filter input { width: 100%; }
        ul.spaces { list-style: none; margin: 0; padding: 0; }
        ul.spaces li {
          display: flex; align-items: center; justify-content: space-between;
          gap: 1rem; padding: .7rem .5rem;
          border-bottom: 1px solid var(--line);
          border-radius: .375rem;
          transition: background .12s ease;
        }
        ul.spaces li:first-child { border-top: 1px solid var(--line); }
        ul.spaces li:hover { background: var(--hover); }
        ul.spaces li[hidden] { display: none; }
        ul.spaces form { margin: 0; }
        ul.spaces label.pick {
          display: flex; align-items: flex-start; gap: .7rem;
          margin: 0 auto 0 0; cursor: pointer;
        }
        ul.spaces label.pick input {
          width: 1.125rem; height: 1.125rem; min-height: 0; margin-top: .2rem;
          accent-color: var(--accent);
        }
        ul.spaces label.pick span { display: block; }
        ul.spaces label.pick strong { font-weight: 600; }
        ul.spaces label.pick small {
          margin-top: .15rem; font-size: .875rem; color: var(--muted);
          font-variant-numeric: tabular-nums;
        }
        a.read { font-size: .9375rem; font-weight: 600; }
        /* A run in progress says so where the decision is: a dot, the words the
           run reports, and the way to it. */
        .run {
          display: flex; align-items: center; gap: .6rem; flex-wrap: wrap;
          margin: 0 0 1rem; padding: .6rem .8rem;
          border: 1px solid var(--line); border-radius: var(--radius);
          background: var(--hover); font-size: .9375rem;
        }
        .run.error { color: var(--danger); border-color: color-mix(in srgb, var(--danger) 40%, transparent); }
        .dot {
          width: .5rem; height: .5rem; border-radius: 50%;
          background: var(--accent); animation: pulse 1.6s ease-in-out infinite;
        }
        .run.error .dot { background: var(--danger); animation: none; }
        @keyframes pulse { 50% { opacity: .35; } }
        .status { margin: 2.5rem 0 0; font-size: .875rem; color: var(--muted); }
        .spinner {
          width: 1.25rem; height: 1.25rem; margin: 0 0 1rem;
          border: 2px solid var(--line); border-top-color: var(--accent);
          border-radius: 50%; animation: spin .8s linear infinite;
        }
        @keyframes spin { to { transform: rotate(360deg); } }
        @media (prefers-reduced-motion: reduce) {
          * { transition: none !important; animation: none !important; }
          .spinner { animation-duration: 3s !important; }
        }
      </style>
    </head>
    <body#{if opts[:nav] == false, do: ~s( class="plain"), else: ""}>
    #{if opts[:nav] == false, do: "", else: sidebar(opts[:current])}<main>
    #{if opts[:status], do: ~s(<p class="status" role="status">#{escape(opts[:status])}</p>), else: ""}
    #{body}
    </main>
    #{if opts[:script], do: ~s(<script defer src="/__tool/assets/app.js"></script>), else: ""}
    #{painted()}
    </body>
    </html>
    """
  end

  # The one line that says what a window can see. It is here, in the shell every
  # tool page is built from, because the claim is about the document and not about
  # any one screen: the window is the only thing that runs a page's script, so
  # this is the difference between "the server served HTML" and "somebody is
  # looking at it" (see `ConfluencePhxMirror.Desktop.Web.Paint`).
  #
  # It reports the *live document*, not the markup the server sent. A path alone
  # would let a window that drew an empty page pass — `/` is the setup form on a
  # fresh workspace and the mirror's home on a configured one — so the boxes a
  # person types into, the heading above them and the word on the button are what
  # is read here, from the DOM that the webview built.
  #
  # Visible box, not every input: a page keeps hidden fields for its own script,
  # and counting those would let a screen with nothing to type into pass.
  defp painted do
    ~S"""
    <script>
    (function () {
      function label(el) { return el.name || el.id || el.type; }

      var fields = Array.prototype.slice
        .call(document.querySelectorAll("input, select, textarea"))
        .filter(function (el) { return el.getClientRects().length > 0; })
        .map(label);

      function reading(selector) {
        var found = document.querySelector(selector);
        return found ? found.textContent.trim() : "";
      }

      var query = "path=" + encodeURIComponent(location.pathname) +
        "&title=" + encodeURIComponent(document.title || "") +
        "&heading=" + encodeURIComponent(reading("h1")) +
        "&fields=" + encodeURIComponent(fields.join(",")) +
        "&button=" + encodeURIComponent(reading("button"));

      fetch("/__tool/painted?" + query, { method: "POST" });
    })();
    </script>
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
        #{entry("/__tool", "Overview", current)}
        #{entry("/__tool/setup", "Connection", current)}
      </div>

      <div class="section">
        <span>Mirror</span>
        #{entry("/__tool/spaces", "Spaces", current)}
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
