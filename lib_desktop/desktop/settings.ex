defmodule ConfluencePhxMirror.Desktop.Settings do
  @moduledoc """
  What the tool remembers about a workspace, and where it keeps it.

  A workspace is one folder and one Confluence site. The folder holds the
  catalogue and the attachments; the settings file holds what identifies the
  workspace — a generated id, the site, the account it signs in as — and never
  holds the secret. The secret belongs to the OS credential store, keyed by that
  id (see `ConfluencePhxMirror.Desktop.Credentials`).

  The id is generated once and stored rather than derived from the folder path.
  A folder that is moved or renamed is still the same workspace, and its
  credential has to be found again; two folders can point at two different sites
  and must not share one.

  None of this is configuration. `config/*.exs` is read before the application
  starts and before there is anyone to ask, so it can only hold the default
  folder. Everything here is read at boot from a settings file in the OS's
  per-user configuration directory — a fixed place, which is how an app finds
  the folder it was told about.
  """

  require Logger

  alias ConfluencePhxMirror.Blobs.LocalStore
  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Desktop.Credentials

  @app :confluence_phx_mirror
  @app_name "confluence-export"
  @settings "settings.json"

  # ---------------------------------------------------------------------------
  # Where
  # ---------------------------------------------------------------------------

  @doc "The folder used before anyone has chosen one."
  @spec default_root() :: Path.t()
  def default_root, do: :filename.basedir(:user_data, @app_name)

  @doc "The settings file, which does nothing but describe a workspace."
  @spec file() :: Path.t()
  def file, do: Path.join(:filename.basedir(:user_config, @app_name), @settings)

  @doc "The folder this workspace is kept in."
  @spec root() :: Path.t()
  def root do
    case read() do
      %{"root" => root} when is_binary(root) -> root
      _ -> default_root()
    end
  end

  @doc "The catalogue."
  @spec database() :: Path.t()
  def database, do: Path.join(root(), "catalogue.db")

  @doc "The attachments."
  @spec blobs() :: Path.t()
  def blobs, do: Path.join(root(), "blobs")

  @doc """
  Records `path` as the folder to use from now on.

  It fails rather than guessing. A folder that cannot be created, or that exists
  and refuses a write — a read-only volume, somebody else's directory — is
  reported to the person who picked it, instead of surfacing as the first page
  that will not save.
  """
  @spec choose_root(Path.t()) :: :ok | {:error, term()}
  def choose_root(path) when is_binary(path) do
    with :ok <- create(path),
         :ok <- prove_writable(path) do
      update(fn settings -> Map.put(settings, "root", Path.expand(path)) end)
      apply_runtime_config()
    end
  end

  # ---------------------------------------------------------------------------
  # What it mirrors
  # ---------------------------------------------------------------------------

  @doc """
  This workspace's id, generated the first time it is asked for.

  It is the key the credential store uses, so it must survive a folder being
  moved. Generated with `Ecto.UUID` because it is already a dependency and a
  random UUID carries no information about the machine or the person.
  """
  @spec id() :: String.t()
  def id do
    case read() do
      %{"id" => id} when is_binary(id) -> id
      _settings -> Map.fetch!(update(&Map.put_new(&1, "id", Ecto.UUID.generate())), "id")
    end
  end

  @doc """
  The site this workspace mirrors, as a URL, or `nil`.

  The workspace wins; the environment is what an unconfigured one falls back to.
  That is how a machine provisioned the way the server is provisioned —
  `CM_CONFLUENCE_SITE`, `CM_ATL_EMAIL`, `CM_ATL_TOKEN` — opens straight onto the
  mirror instead of a form asking for what it was already told.
  """
  @spec site() :: String.t() | nil
  def site, do: read()["site"] || from_env("CM_CONFLUENCE_SITE")

  @doc "The account it signs in as, or `nil` for a bearer token."
  @spec email() :: String.t() | nil
  def email, do: read()["email"] || from_env("CM_ATL_EMAIL")

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

  # The id is read rather than generated: asking whether a workspace is ready
  # must not be the thing that creates it.
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

  # The id is read rather than generated: asking whether a workspace is ready
  # must not be the thing that creates it.
  defp stored_secret do
    case read()["id"] do
      nil -> {:error, :not_found}
      id -> Credentials.fetch(id)
    end
  end

  defp from_env(name) do
    case System.get_env(name) do
      nil -> nil
      value -> blank(value)
    end
  end

  @doc """
  Saves what identifies the site: its URL and the account.

  Neither is a secret, so both live here. An empty `email` means the token is
  used as a bearer token, which is how Confluence Server/DC personal access
  tokens work; with an email it is an Atlassian API token.
  """
  @spec store(map()) :: :ok | {:error, term()}
  def store(attrs) when is_map(attrs) do
    with {:ok, site} <- validate_site(attrs) do
      update(fn settings ->
        settings
        |> Map.put("site", site)
        |> Map.put("email", blank(attrs[:email] || attrs["email"]))
      end)

      apply_runtime_config()
    end
  end

  @doc """
  First run, and every later change to the connection: a URL, an account and its
  secret, in one call.

  This is the whole of what the UI needs before the tool can sync. The folder is
  created here rather than when the first page is written, so a credential with
  nowhere to put the catalogue fails at the moment somebody pressed the button
  instead of three minutes later.

  The folder is the one already chosen, or — on a first run — `default_root/0`,
  the per-user application data directory. It is app-owned staging, not the
  deliverable: the archive a person wants to keep is written where they choose at
  export time.
  """
  @spec configure(map()) :: {:ok, String.t()} | {:error, term()}
  def configure(attrs) when is_map(attrs) do
    with {:ok, secret} <- secret(attrs),
         :ok <- store(attrs),
         :ok <- ensure_root() do
      workspace_id = id()
      :ok = Credentials.put(workspace_id, secret)
      {:ok, workspace_id}
    end
  end

  @doc "Whether this install has been set up."
  @spec first_run?() :: boolean()
  def first_run?, do: not File.exists?(file())

  @doc "Creates the workspace folder and the attachments folder under it."
  @spec ensure_root() :: :ok | {:error, term()}
  def ensure_root do
    with :ok <- create(root()), do: create(blobs())
  end

  @doc "Forgets everything about this workspace, including its secret."
  @spec forget() :: :ok
  def forget do
    Credentials.delete(id())
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
    put_site_config()
    :ok
  end

  @doc """
  Loads the workspace's secret into the HTTP client's configuration.

  The token is not part of `apply_runtime_config/0` on purpose. It stays in the
  credential store until something is about to use it, and `end_session/0` takes
  it back out, so it is present in the application environment only while a run
  is talking to Confluence rather than for the whole life of the process.
  """
  @spec begin_session() :: :ok | {:error, term()}
  def begin_session do
    with {:ok, token} <- secret() do
      put_http_source(api_token: token)
    end
  end

  @doc "Removes the secret from the HTTP client's configuration."
  @spec end_session() :: :ok
  def end_session do
    config = Application.get_env(@app, HttpSource, [])
    Application.put_env(@app, HttpSource, Keyword.delete(config, :api_token))
  end

  @doc """
  Reopens the catalogue in the current folder.

  A repo reads its `:database` once, when it starts, so a folder chosen while the
  app is running takes effect when the repo restarts — which is what this does,
  through the supervisor that owns it. `Desktop.Repo.init/2` reads the new path.
  """
  @spec restart_repo() :: {:ok, pid()} | {:error, term()}
  def restart_repo do
    supervisor = ConfluencePhxMirror.Desktop.Supervisor
    repo = ConfluencePhxMirror.Desktop.Repo

    with :ok <- Supervisor.terminate_child(supervisor, repo) do
      Supervisor.restart_child(supervisor, repo)
    end
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

  defp put_site_config do
    put_http_source(base_url: site(), email: email())
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
      nil -> {:error, :secret_required}
      secret -> {:ok, secret}
    end
  end

  defp validate_site(attrs) do    case blank(attrs[:site] || attrs["site"]) do
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

  # A directory can exist and still refuse a write. The question is answered
  # once, here, rather than on the first attachment.
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
