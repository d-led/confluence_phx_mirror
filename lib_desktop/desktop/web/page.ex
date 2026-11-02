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
    # What is already known is already filled in: the workspace's own values, or
    # the environment's on a machine that was provisioned rather than set up.
    site = escape(assigns[:site] || Settings.site() || "")
    email = escape(assigns[:email] || Settings.email() || "")

    error =
      case assigns[:error] do
        nil -> ""
        message -> ~s(<p class="error" role="alert">#{escape(message)}</p>)
      end

    document("Set up the mirror", """
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
        <input name="secret" type="password" required>
        <small>Stored in this machine's credential store, never in a file.</small>
      </label>
      <button type="submit">Save and continue</button>
    </form>
    """)
  end

  @doc "The screen shown once the connection is configured."
  @spec home() :: String.t()
  def home do
    document("Confluence mirror export", """
    <h1>Ready</h1>
    <p class="lede">This workspace mirrors <strong>#{escape(Settings.site() || "")}</strong>.</p>
    <dl>
      <dt>Folder</dt><dd>#{escape(Settings.root())}</dd>
      <dt>Attachments</dt><dd>#{escape(Settings.blobs())}</dd>
    </dl>
    <p><a href="/spaces">Choose spaces to mirror</a></p>
    <p><a href="/setup">Change the connection</a></p>
    """)
  end

  @doc """
  The spaces the source offers, with what the catalogue already holds.

  A space that has been mirrored before says how many pages it has, so the
  button is a choice between "mirror" and "mirror again" rather than a guess.
  """
  @spec spaces([map()], %{String.t() => non_neg_integer()}) :: String.t()
  def spaces(spaces, counts) do
    rows =
      Enum.map_join(spaces, "", fn space ->
        mirrored = Map.get(counts, space.key, 0)

        """
        <li>
          <div>
            <strong>#{escape(space.name)}</strong>
            <small>#{escape(space.key)}#{
          if mirrored > 0, do: " · #{mirrored} pages mirrored", else: " · not mirrored yet"
        }</small>
          </div>
          <form method="post" action="/mirror">
            <input type="hidden" name="space" value="#{escape(space.key)}">
            <button type="submit" class="secondary">#{if mirrored > 0, do: "Mirror again", else: "Mirror"}</button>
          </form>
        </li>
        """
      end)

    document("Spaces", """
    <h1>Spaces</h1>
    <p class="lede">Choose what to copy from #{escape(Settings.site() || "Confluence")}.</p>
    <ul class="spaces">#{rows}</ul>
    <p><a href="/">Back</a></p>
    """)
  end

  @doc "How the mirror is doing, in the words the run itself reports."
  @spec mirror(map()) :: String.t()
  def mirror(%{state: :running} = status) do
    document(
      "Mirroring #{status.space_key}",
      """
      <h1>Mirroring #{escape(status.space_key)}</h1>
      <p class="lede">#{status.done} of #{status.total} pages</p>
      <p class="note">This page follows the run; it is not a progress bar that
      guesses.</p>
      """,
      refresh: true
    )
  end

  def mirror(%{state: :done} = status) do
    document("Mirrored #{status.space_key}", """
    <h1>Mirrored #{escape(status.space_key)}</h1>
    <p class="lede">#{status.total} pages are in the catalogue.</p>
    <p class="note">Writing the archive comes next.</p>
    <p><a href="/spaces">Back to spaces</a></p>
    """)
  end

  def mirror(%{state: :error} = status) do
    document("Mirror stopped", """
    <h1>Mirror stopped</h1>
    <p class="lede">#{escape(status.space_key)} could not be finished.</p>
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
        ul.spaces { list-style: none; margin: 0 0 1.5rem; padding: 0; }
        ul.spaces li { display: flex; align-items: center; justify-content: space-between;
                       gap: 1rem; padding: .75rem 0; border-bottom: 1px solid rgba(127,127,127,.2); }
        ul.spaces li:first-child { border-top: 1px solid rgba(127,127,127,.2); }
        ul.spaces form { margin: 0; }
        button.secondary { width: auto; padding: .4rem .9rem; font-size: .8125rem;
                           background: transparent; color: #2f5fe0;
                           border: 1px solid rgba(47,95,224,.4); }
        button.secondary:hover { background: rgba(47,95,224,.08); }
      </style>
    </head>
    <body><main>#{body}</main></body>
    </html>
    """
  end

  defp escape(value) when is_binary(value), do: Plug.HTML.html_escape(value) |> to_string()
end
