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

  @app :confluence_phx_mirror
  @app_name "confluence-export"
  @settings "settings.json"

  # One tool, one workspace: the credential store is keyed by a constant, so a
  # lost settings file cannot lose the token with it.
  @account "workspace"

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
  def secret do
    with {:error, _none} <- stored_secret() do
      case from_env("CM_ATL_TOKEN") do
        nil -> {:error, :not_found}
        token -> {:ok, token}
      end
    end
  end

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

  # The account is a constant, so asking whether a workspace is ready cannot be
  # the thing that creates it.
  defp stored_secret, do: Credentials.fetch(@account)

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
      if root() != before, do: restart_repo()
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
    with {:ok, secret} <- secret(attrs),
         :ok <- store(attrs),
         :ok <- ensure_root(),
         :ok = Credentials.put(@account, secret) do
      # The token reaches the credential store only here, so the client has to be
      # told again: `store/1` applied the configuration while the previous secret
      # was still the only one available, and a connection holding last week's
      # token fails exactly like one holding none.
      apply_runtime_config()
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
    Credentials.delete(@account)
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
  """
  @spec apply_runtime_config() :: :ok
  def apply_runtime_config do
    Application.put_env(@app, :blob_store, LocalStore)
    Application.put_env(@app, :blob_root, blobs())
    # Archives are built in the workspace too, beside the catalogue they copy:
    # the folder the home screen names is the folder a person looks in.
    Application.put_env(@app, :export_tmp_dir, root())
    put_repo_config()
    put_site_config()
    put_source_config()
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

  # The token comes with the rest of the connection. It used to be loaded only
  # for the length of a run, by a `begin_session/0` that nothing ever called —
  # and a token nobody loads is a site that answers 401. `HttpSource` reads its
  # configuration per request, so what is set here is in force for every call
  # that follows.
  defp put_site_config do
    put_http_source(base_url: site(), email: email(), api_token: token())
  end

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
  defp put_source_config do
    cond do
      blank(site()) -> :ok
      System.get_env("CM_SOURCE") -> :ok
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
  defp secret(attrs) do
    case blank(attrs[:secret] || attrs["secret"]) do
      # Blank keeps what the machine already has: the keyring's token, or the one
      # the environment was started with. Saving then stores it, so the tool no
      # longer depends on the shell that launched it.
      nil ->
        case secret() do
          {:ok, secret} -> {:ok, secret}
          {:error, :not_found} -> {:error, :secret_required}
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
