defmodule ConfluencePhxMirror.Desktop.Settings do
  @moduledoc """
  What the tool remembers about a workspace, and where it keeps it.

  A workspace is one folder and one Confluence site. The folder is fixed —
  `root/0`, under the user's application data directory — and it holds the
  catalogue and the attachments. The settings file beside it records which site
  that is and which account it signs in as; the secret is not in the file, and
  belongs to the OS credential store under a constant key (see
  `ConfluencePhxMirror.Desktop.Credentials`).

  Nothing here is chosen at run time. A folder that can be picked is a path that
  has to be remembered, in a file that can be lost, stale or unreadable — for a
  decision a person made once. One tool on one machine is one workspace, and the
  credential store says so too: losing the record costs the site's address, not
  the token.

  None of this is configuration either. `config/*.exs` is read before the
  application starts and before there is anyone to ask; everything here is read
  at boot from a file in the OS's per-user directory, which is how an app finds
  what it was told.
  """

  require Logger

  alias ConfluencePhxMirror.Blobs.LocalStore
  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Desktop.Credentials
  alias ConfluencePhxMirror.Sites

  @app :confluence_phx_mirror
  @app_name "confluence-export"
  @settings "settings.json"

  # The prefix of every credential-store account. The account itself is the
  # prefix *and the site* — see `account/1`.
  @account "workspace"

  # What the account was before it carried the site: one entry for the whole
  # machine, holding the token of whatever site happened to be configured. Only
  # `adopt_legacy_secret/0` reads it, once, to move the token to that site.
  @legacy_account "workspace"

  @doc """
  The credential-store account a token for `site` belongs to.

  A machine is not a site. The same window can be pointed at another URL, and a
  token for `acme.atlassian.net` must never be the token *found* for, or sent
  to, whatever address is in the form next — so the account carries the site,
  normalised (`https://X/wiki/` and `https://x/wiki` are one site, see
  `ConfluencePhxMirror.SiteUrl`). A token is then only ever found for the
  address it was stored for: a changed site needs a token of its own, which is
  the refusal that stops one site's secret from reaching another.

  The account is also what a person sees in Keychain Access, which is why it is
  the address and not a hash of it.
  """
  @spec account(String.t() | nil) :: String.t() | nil
  def account(site) do
    case ConfluencePhxMirror.SiteUrl.normalize(site) do
      nil -> nil
      url -> @account <> ":" <> url
    end
  end

  @doc """
  Moves a token stored under the old constant account to the site it was for.

  Before the account carried the site, the machine held one token: the one for
  the site configured at the time, which is the site the settings file names.
  It is filed under that site now and the old entry is deleted — once, at boot,
  and only when a site is known. Nothing else can inherit it, and a machine that
  never had one pays a single `fetch/1` for the answer.
  """
  @spec adopt_legacy_secret() :: :ok
  def adopt_legacy_secret do
    with site when is_binary(site) <- site(),
         id when is_binary(id) <- account(site),
         {:ok, secret} <- Credentials.fetch(@legacy_account) do
      case Credentials.put(id, secret) do
        :ok -> Credentials.delete(@legacy_account)
        {:error, _refused} -> :ok
      end

      :ok
    else
      _no_site_or_no_legacy_token -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Where
  # ---------------------------------------------------------------------------

  @doc """
  The folder this workspace is kept in: the same one on every machine.

  It is fixed rather than chosen — see the module doc.
  """
  @spec root() :: Path.t()
  def root, do: read()["root"] || default_root()

  @doc "The folder a workspace uses until somebody names another one."
  @spec default_root() :: Path.t()
  def default_root, do: :filename.basedir(:user_data, @app_name)

  @doc """
  The file that records which site this workspace mirrors, and as whom.

  Its home is the application data directory, not the workspace folder: the file
  says *where* the workspace is, so it cannot be found by first knowing the
  workspace. In the default case the two are the same folder and the record sits
  beside the catalogue; when a folder is chosen, the record stays here and points
  at it.
  """
  @spec file() :: Path.t()
  def file, do: Path.join(default_root(), @settings)

  @doc "The catalogue."
  @spec database() :: Path.t()
  def database, do: Path.join(root(), "catalogue.db")

  @doc "The attachments."
  @spec blobs() :: Path.t()
  def blobs, do: Path.join(root(), "blobs")

  @doc """
  The port the window's server prefers, overridable without a rebuild.

  `CONFLUENCE_EXPORT_PORT` first — a script or a service names it — then the
  `port` key in `settings.json`, which is what a person who double-clicks the app
  can change, because a window has no shell to export anything from. Anything
  that is not a port number is logged and ignored: refusing to start over a typo
  would take the tool away from the one person who could fix it.

  A fixed number is the point. The MCP endpoint is a URL an assistant is pointed
  at once, and an ephemeral port means re-pointing it at every launch.
  """
  @spec port() :: :inet.port_number()
  def port do
    Enum.find_value(
      [from_env("CONFLUENCE_EXPORT_PORT"), read()["port"]],
      default_port(),
      &to_port/1
    )
  end

  @doc """
  The port used when neither the environment nor the settings file names one.

  43_100 rather than a round number: 4_000 is a server someone started by hand
  and 42_800 is the neighbouring Monty tool, and a fixed port that collides is
  the one thing this was meant to avoid.
  """
  @spec default_port() :: :inet.port_number()
  def default_port, do: 43_100

  defp to_port(nil), do: nil
  defp to_port(port) when is_integer(port) and port > 0 and port < 65_536, do: port

  defp to_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} -> to_port(port)
      _not_a_port -> not_a_port(value)
    end
  end

  defp to_port(value), do: not_a_port(value)

  defp not_a_port(value) do
    Logger.warning("ignoring #{inspect(value)} as a port; using #{default_port()}")
    nil
  end

  # ---------------------------------------------------------------------------
  # What it mirrors
  # ---------------------------------------------------------------------------

  @doc """
  The site this workspace mirrors, as a URL, or `nil`.

  Only what this tool recorded. The environment is not consulted: it is not
  something a person typed into this window, it is not what the window can
  change, and a `CM_CONFLUENCE_SITE` in a shell makes the form that would have
  saved a site unreachable — which is how a workspace ends up configured ten
  times and remembering none of it. What the environment says is a *suggestion*
  for that form (`suggested_site/0`), not an answer to this question.
  """
  @spec site() :: String.t() | nil
  def site, do: read()["site"]

  @doc "The account it signs in as, or `nil` for a bearer token."
  @spec email() :: String.t() | nil
  def email, do: read()["email"]

  @doc """
  The site a first-run form offers, from `CM_CONFLUENCE_SITE`. `nil` when the
  environment says nothing.

  A suggestion, not an answer: it fills the field so a machine that was
  provisioned does not have its URL typed by hand, and no more. The workspace is
  configured when the form is saved — which is also when the value starts to
  survive a restart.
  """
  @spec suggested_site() :: String.t() | nil
  def suggested_site, do: from_env("CM_CONFLUENCE_SITE")

  @doc "The account a first-run form offers, from `CM_ATL_EMAIL`."
  @spec suggested_email() :: String.t() | nil
  def suggested_email, do: from_env("CM_ATL_EMAIL")

  @doc "The token, from the credential store, or the environment's when there is none."
  @spec secret() :: {:ok, String.t()} | {:error, :not_found}
  def secret, do: secret_for(site())

  @doc """
  Whether a token is already available — in the credential store, or in
  `CM_ATL_TOKEN`.

  The form asks for a token only when this is false: asking for one the machine
  already has is how a form teaches people to paste secrets into pages.
  """
  @spec secret_available?() :: boolean()
  def secret_available?, do: secret() != {:error, :not_found}

  @doc """
  Whether this workspace can be used to reach Confluence yet.

  `:ready`, or `{:needs, missing}` naming what is absent — so the screen that
  asks for it can ask for the right thing instead of a form that rejects a
  submission it could have prevented.
  """
  @spec readiness() :: :ready | {:needs, [atom()]}
  def readiness do
    case missing() do
      [] -> :ready
      missing -> {:needs, missing}
    end
  end

  @doc "Whether this workspace can be used to reach Confluence yet."
  @spec configured?() :: boolean()
  def configured?, do: readiness() == :ready

  # Asking whether a workspace is ready must not be the thing that creates it,
  # so this only reads.
  defp missing do
    []
    |> require_site()
    |> require_secret()
  end

  defp require_site(acc) do
    if blank(site()), do: acc, else: acc ++ [:site]
  end

  defp require_secret(acc) do
    case secret() do
      {:ok, _secret} -> acc
      {:error, _reason} -> acc ++ [:secret]
    end
  end

  # The account a token is filed under carries the site, so asking whether a
  # workspace is ready cannot be the thing that creates it.
  defp stored_secret(site) do
    case account(site) do
      nil -> {:error, :not_found}
      id -> Credentials.fetch(id)
    end
  end

  defp secret_for(site) do
    case stored_secret(site) do
      {:ok, secret} -> {:ok, secret}
      {:error, _none} -> env_secret(site)
    end
  end

  # A token in the environment is the token of the site in the environment. It
  # arrives with `CM_CONFLUENCE_SITE` and belongs to that address; honouring it
  # for whatever address a form holds would send a provisioned secret to a site
  # nobody provisioned, which is the whole of what keying by site prevents.
  defp env_secret(site) do
    with env_site when is_binary(env_site) <- suggested_site(),
         true <- ConfluencePhxMirror.SiteUrl.same?(site, env_site),
         token when is_binary(token) <- from_env("CM_ATL_TOKEN") do
      {:ok, token}
    else
      _not_this_site -> {:error, :not_found}
    end
  end

  defp from_env(name) do
    case System.get_env(name) do
      nil -> nil
      value -> blank(value)
    end
  end

  @doc """
  Saves what identifies the site: its URL, the account and the folder.

  None of these is a secret, so all of them live here. An empty `email` means
  the token is used as a bearer token, which is how Confluence Server/DC
  personal access tokens work; with an email it is an Atlassian API token.

  A folder that changed while the tool is running reopens the catalogue there:
  the repository reads its path once, when it starts.
  """
  @spec store(map()) :: :ok | {:error, term()}
  def store(attrs) when is_map(attrs) do
    with {:ok, site} <- validate_site(attrs),
         {:ok, folder} <- validate_root(attrs) do
      before = root()

      update(fn settings ->
        settings
        |> Map.put("site", site)
        |> Map.put("email", blank(attrs[:email] || attrs["email"]))
        |> put_folder(folder)
      end)

      apply_runtime_config()

      if root() != before do
        restart_repo()

        # A folder nobody has used has no schema: the migrations run at boot, for
        # the folder the tool booted with. Reopening the repo on a new file is not
        # enough — every query would answer "no such table" and the window would
        # show a connection error about a site that is perfectly reachable.
        ConfluencePhxMirror.Desktop.Setup.prepare(database())
        ConfluencePhxMirror.Desktop.Setup.migrate()
      end

      # A window keeps running when it disagrees with its folder, so the question
      # is asked again whenever the connection changes: saving the right site
      # clears the warning without a restart.
      Sites.refresh_conflict()
      :ok
    end
  end

  # No folder in the form means "the one in force": a field nobody touched must
  # not move the catalogue.
  defp put_folder(settings, nil), do: settings
  defp put_folder(settings, folder), do: Map.put(settings, "root", folder)

  defp validate_root(attrs) do
    case blank(attrs[:root] || attrs["root"]) do
      nil ->
        {:ok, nil}

      path ->
        expanded = Path.expand(path)

        with :ok <- create(expanded),
             :ok <- prove_writable(expanded) do
          {:ok, expanded}
        end
    end
  end

  @doc """
  Reopens the catalogue in the folder in force now.

  A repo reads its `:database` once, when it starts; this is how a folder chosen
  in the window takes effect without restarting the tool.
  """
  @spec restart_repo() :: {:ok, pid()} | {:error, term()}
  def restart_repo do
    supervisor = ConfluencePhxMirror.Desktop.Supervisor
    repo = ConfluencePhxMirror.Repo

    with :ok <- Supervisor.terminate_child(supervisor, repo) do
      Supervisor.restart_child(supervisor, repo)
    end
  end

  @doc """
  First run, and every later change to the connection: a URL, an account and its
  secret, in one call.

  This is the whole of what the UI needs before the tool can sync. The folder —
  and the attachments folder under it — is created here rather than when the
  first page is written, so a credential with nowhere to put the catalogue fails
  at the moment somebody pressed the button instead of three minutes later.
  """
  @spec configure(map()) :: :ok | {:error, term()}
  def configure(attrs) when is_map(attrs) do
    # The site first: a token is stored for a site, so the site being saved is
    # the one whose token this is — not the one that was configured before it.
    with {:ok, site} <- validate_site(attrs),
         {:ok, secret} <- secret(attrs, site),
         :ok <- store(attrs),
         :ok <- ensure_root(),
         :ok <- store_secret(site, secret) do
      # The token reaches the credential store only here, so the client has to be
      # told again: `store/1` applied the configuration while the previous secret
      # was still the only one available, and a connection holding last week's
      # token fails exactly like one holding none.
      apply_runtime_config()
      apply_credentials()

      # And the space list is asked again. It is fetched at boot and kept, so on a
      # fresh machine it holds the failure of asking without a token — or, worse,
      # the two spaces of the bundled demo the tool started on. Either one is a
      # screen that shows the wrong site until something asks again, and saving
      # the connection is exactly the moment to ask.
      ConfluencePhxMirror.Desktop.Spaces.refresh()
    end
  end

  # A credential store that refuses is a thing a person can fix — a locked login
  # keychain, a machine where the tool was never given access — and a refused
  # write is not a reason to take the window down with a `MatchError`. The site
  # and folder are already saved by now, so the answer says what did land and
  # what did not.
  defp store_secret(site, secret) do
    case Credentials.put(account(site), secret) do
      :ok -> :ok
      {:error, reason} -> {:error, {:secret_not_stored, reason}}
    end
  end

  @doc "Whether this install has been set up: whether a site has been recorded."
  @spec first_run?() :: boolean()
  def first_run?, do: is_nil(blank(site()))

  @doc "Creates the workspace folder and the attachments folder under it."
  @spec ensure_root() :: :ok | {:error, term()}
  def ensure_root do
    with :ok <- create(root()), do: create(blobs())
  end

  @doc "Forgets everything about this workspace, including its secret."
  @spec forget() :: :ok
  def forget do
    with id when is_binary(id) <- account(site()), do: Credentials.delete(id)
    File.rm(file())
    :ok
  end

  # ---------------------------------------------------------------------------
  # Runtime
  # ---------------------------------------------------------------------------

  @doc """
  Points the application at this workspace's folder and site.

  Called at boot and after a change. `Blobs.Store` resolves its root when it is
  used, not when it is configured, so setting it here is enough; `HttpSource`
  reads its configuration per request.

  The token is deliberately not part of this — see `apply_credentials/0`.
  """
  @spec apply_runtime_config() :: :ok
  def apply_runtime_config do
    put_log_file()
    Application.put_env(@app, :blob_store, LocalStore)
    Application.put_env(@app, :blob_root, blobs())
    # Archives are built in the workspace too, beside the catalogue they copy:
    # the folder the home screen names is the folder a person looks in.
    Application.put_env(@app, :export_tmp_dir, root())
    put_repo_config()
    put_http_source(base_url: site(), email: email())
    put_source_config()
    put_workspace_info()
    :ok
  end

  # The tool's log is a file it owns, not the pipe it was started on. The window
  # reads the sidecar's output and stops reading when it closes, and the next
  # write to a pipe nobody reads raises `:badarg` (`:erlang.display_string`,
  # cause `:epipe`) *in whichever process logged* — a sync once died that way, in
  # a page's task, seven frames below anything it had done. The destination is
  # chosen here and not in `config/desktop.exs` because a release bakes its
  # config at build time, and this folder belongs to the person running the
  # tool, not to whoever built it.
  defp put_log_file do
    folder = Path.join(root(), "logs")
    File.mkdir_p(folder)

    with {:ok, handler} <- :logger.get_handler_config(:default) do
      relocate_log(handler, String.to_charlist(Path.join(folder, "desktop.log")))
    end

    :ok
  end

  # `file:` wants a charlist, and the handler will not move house later: its
  # destination is fixed when it is added, so the handler is replaced by one
  # that has everything the build gave it except where it writes.
  defp relocate_log(%{config: %{file: file}}, file), do: :ok

  defp relocate_log(handler, file) do
    :ok = :logger.remove_handler(:default)

    :logger.add_handler(:default, :logger_std_h, %{
      level: handler.level,
      filters: handler.filters,
      filter_default: handler.filter_default,
      formatter: handler.formatter,
      config: %{
        file: file,
        max_no_bytes: 5_000_000,
        max_no_files: 3
      }
    })
  end

  # What only a desktop tool can say about itself, for the MCP configuration tool
  # to include: the folder the catalogue lives in, the address an assistant is
  # pointed at, the site and the account. A function rather than a map because
  # the port is known only once the listener has bound, and a screen that moves
  # the workspace changes the folder while the tool is running. `lib_desktop`
  # hands it over; `lib` never reaches back into this build.
  defp put_workspace_info do
    Application.put_env(@app, :workspace_info, fn ->
      port = Application.get_env(@app, :desktop_port) || port()

      %{
        root: root(),
        site: site(),
        account: email(),
        port: port,
        mcp_url: "http://127.0.0.1:#{port}/api/mcp"
      }
    end)
  end

  @doc """
  Hands the client the workspace's token.

  Apart from `apply_runtime_config/0` because reading the token goes through the
  OS credential store, and that store may put a dialog in front of everything and
  wait for an answer — macOS asks for the login password when an application it
  has not seen before reads the item, and *a copy of the tool is an application it
  has not seen before*, which is how somebody first runs a build they downloaded.
  At boot that dialog is raised before the window exists, and a tool that is
  waiting behind it looks like a tool that never started.

  So the call belongs after the listener has printed its address, with the window
  already on screen to say what is being asked. A token nobody loads is still a
  site that answers 401, which is why it happens at all: `HttpSource` reads its
  configuration per request, so what is set here is in force for every call that
  follows.
  """
  @spec apply_credentials() :: :ok
  def apply_credentials do
    put_http_source(api_token: token())
    :ok
  end

  # The repo reads `:database` when it starts, so the path is written here first.
  defp put_repo_config do
    current = Application.get_env(@app, ConfluencePhxMirror.Repo, [])

    Application.put_env(
      @app,
      ConfluencePhxMirror.Repo,
      current
      |> Keyword.put(:database, database())
      |> Keyword.put_new(:journal_mode, :wal)
      |> Keyword.put_new(:pool_size, 1)
    )
  end

  # ---------------------------------------------------------------------------
  # The file
  # ---------------------------------------------------------------------------

  defp read do
    with {:ok, contents} <- File.read(file()),
         {:ok, settings} when is_map(settings) <- JSON.decode(contents) do
      settings
    else
      {:error, :enoent} ->
        %{}

      other ->
        # Unreadable settings are not a reason to stop: every field has a
        # default. They are a reason to say so, once.
        Logger.warning("ignoring unreadable settings at #{file()}: #{inspect(other)}")
        %{}
    end
  end

  defp update(fun) do
    settings = fun.(read())
    write(settings)
    settings
  end

  defp write(settings) do
    File.mkdir_p!(Path.dirname(file()))
    File.write!(file(), JSON.encode_to_iodata!(settings))
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp token do
    case secret() do
      {:ok, token} -> token
      {:error, _none} -> nil
    end
  end

  # A deployment that named no source falls back to the demo snapshot, which is
  # the right answer for a mirror nobody has set up. A workspace that knows its
  # site is not that: reading the demo after a person typed their site would
  # ignore the only thing they told us. An operator who named a source out loud
  # keeps it.
  #
  # `present?/1` and not `blank/1`: this is a question, and `blank/1` answers with
  # the *value* — so `cond do blank(site()) -> :ok` was true for every site ever
  # configured, and the tool stayed on the demo snapshot. It only ever reached a
  # real site because `config/runtime.exs` picks `HttpSource` when
  # `CM_CONFLUENCE_SITE`, `CM_ATL_EMAIL` and `CM_ATL_TOKEN` are all exported —
  # which a window started by double-clicking has not got, and the app then
  # refused to start on a folder that belonged to its own site.
  defp put_source_config do
    cond do
      not present?(site()) -> :ok
      present?(System.get_env("CM_SOURCE")) -> :ok
      true -> Application.put_env(@app, :source, HttpSource)
    end
  end

  # Only keys with a value: `HttpSource` reads what is there and falls back to
  # its own defaults, and a nil in this list would be a value.
  defp put_http_source(pairs) do
    config =
      pairs
      |> Enum.reject(fn {_key, value} -> blank(value) == nil end)
      |> Enum.reduce(Application.get_env(@app, HttpSource, []), fn {key, value}, acc ->
        Keyword.put(acc, key, value)
      end)

    Application.put_env(@app, HttpSource, config)
  end

  # A secret is required, not defaulted: an empty one would be stored and then
  # fail as an authentication error from Confluence, which says the wrong thing
  # about what went wrong.
  # The submitted token, or the one this site already has. A blank field is
  # "keep what is stored *for this address*": changing the site therefore needs
  # a token of its own, instead of silently carrying the previous site's over.
  defp secret(attrs, site) do
    case blank(attrs[:secret] || attrs["secret"]) do
      nil ->
        case secret_for(site) do
          {:ok, secret} -> {:ok, secret}
          {:error, _none} -> {:error, :secret_required}
        end

      secret ->
        {:ok, secret}
    end
  end

  defp validate_site(attrs) do
    case blank(attrs[:site] || attrs["site"]) do
      nil ->
        {:error, :site_required}

      site ->
        case URI.parse(site) do
          %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
            {:ok, String.trim_trailing(site, "/")}

          _ ->
            {:error, {:invalid_site, site}}
        end
    end
  end

  defp blank(nil), do: nil
  defp blank(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)

  # A question about a value, where `blank/1` is the value itself. Two different
  # jobs: `blank(attrs[:root])` wants nil-or-the-path, `present?(site())` wants a
  # yes or a no. Using `blank/1` as a condition reads as one and behaves as the
  # other, which is a bug that hides until the environment stops covering it.
  defp present?(value), do: blank(value) != nil

  defp create(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cannot_create, path, reason}}
    end
  end

  # A directory can exist and still refuse a write — a read-only volume, somebody
  # else's folder. Answered once, here, rather than on the first page that will
  # not save.
  defp prove_writable(path) do
    probe = Path.join(path, ".write-test-#{System.unique_integer([:positive])}")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        :ok

      {:error, reason} ->
        {:error, {:not_writable, path, reason}}
    end
  end
end
