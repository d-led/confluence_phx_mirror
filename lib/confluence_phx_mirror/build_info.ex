defmodule ConfluencePhxMirror.BuildInfo do
  @moduledoc """
  What this release was built from: the version, the commit, and the pipeline
  run that produced it, if one did.

  The build writes `priv/build_info.json` *into* the release (`mix build.info`),
  so the answer travels with the artefact instead of being read from whatever
  environment a container happens to start with. A checkout that was never
  built says `dev` — a laptop should not claim to be a build — and `/admin`
  shows the label in its footer, with the run linked when there was one.

  Read once at boot into `:persistent_term`: the footer asks on every admin
  page, and a file read there would be a syscall per request for a value that
  cannot change.
  """

  @term {__MODULE__, :info}
  @filename "build_info.json"

  @typedoc """
  `version` and `revision` are what the build was told; `ci` is nil for a build
  that happened outside a pipeline.
  """
  @type t :: %{
          version: String.t(),
          revision: String.t() | nil,
          built_at: String.t() | nil,
          # `nil` is a build nobody's CI touched, which `dev/0` reports.
          ci:
            %{
              provider: String.t() | nil,
              workflow: String.t() | nil,
              run_number: String.t() | nil,
              run_url: String.t() | nil
            }
            | nil
        }

  @doc "The build the running release came from, read on first use."
  @spec info() :: t()
  def info do
    case :persistent_term.get(@term, :unloaded) do
      :unloaded ->
        info = read()
        :persistent_term.put(@term, info)
        info

      info ->
        info
    end
  end

  @doc """
  A one-line label for humans: `dev`, or `1.2.3+3f2a1c9` — the version, and the
  short commit it was built from when the commit is not the version itself.
  """
  @spec label(t()) :: String.t()
  def label(info \\ info()) do
    case info do
      %{version: "dev"} -> "dev"
      %{version: version, revision: nil} -> version
      %{version: version, revision: revision} -> "#{version}+#{short(revision)}"
    end
  end

  @doc "The pipeline run that built this release, or nil when nothing did."
  @spec ci(t()) :: map() | nil
  def ci(info \\ info()), do: info.ci

  @doc """
  The run's name for a footer link — `ci #42` — or nil outside a pipeline.
  """
  @spec ci_label(t()) :: String.t() | nil
  def ci_label(info \\ info()) do
    case ci(info) do
      %{workflow: workflow, run_number: number}
      when is_binary(workflow) and is_binary(number) ->
        "#{workflow} ##{number}"

      %{workflow: workflow} when is_binary(workflow) and workflow != "" ->
        workflow

      _ ->
        nil
    end
  end

  @doc """
  The whole build as one sentence, for a `title=` attribute: what was built,
  from which commit, when, and by which run.
  """
  @spec description(t()) :: String.t()
  def description(info \\ info()) do
    %{version: version, revision: revision, built_at: built_at, ci: ci} = info

    [
      "version #{version}",
      revision && "commit #{short(revision)}",
      built_at && "built #{built_at}",
      ci && ci[:run_url]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  @doc """
  Writes the build file into a release's `priv` directory.

  `mix build.info` is the caller; the writer lives here so the file it produces
  and the file `read/1` expects are one function pair, and a test can round-trip
  them.
  """
  @spec write(Path.t(), t()) :: :ok
  def write(priv_dir, %{} = info) do
    File.mkdir_p!(priv_dir)

    File.write!(
      Path.join(priv_dir, @filename),
      :json.encode(%{
        "version" => info.version,
        "revision" => json(info.revision),
        "built_at" => json(info.built_at),
        "ci" => json_ci(info.ci)
      })
    )
  end

  # `:json.encode/1` writes any atom other than `null` as a string, so `nil`
  # would arrive as "nil" — a build with no commit and a commit called nil are
  # not the same thing.
  defp json(nil), do: :null
  defp json(value), do: value

  defp json_ci(nil), do: :null

  defp json_ci(ci) do
    %{
      "provider" => json(ci[:provider]),
      "workflow" => json(ci[:workflow]),
      "run_number" => json(ci[:run_number]),
      "run_url" => json(ci[:run_url])
    }
  end

  @doc """
  Reads the build file from a release's `priv` directory.

  No file is not an error: it is a checkout that was never released, and `dev`
  is the truth about it.
  """
  @spec read(Path.t() | nil) :: t()
  def read(priv_dir \\ priv_dir()) do
    with dir when is_binary(dir) <- priv_dir,
         {:ok, contents} <- File.read(Path.join(dir, @filename)),
         {:ok, decoded} <- decode(contents) do
      from_json(decoded)
    else
      _ -> dev()
    end
  end

  # `:json.decode/1` raises on malformed input; a half-written or hand-edited
  # file should read as "no build information", not take the application down.
  defp decode(contents) do
    {:ok, :json.decode(contents)}
  rescue
    _error -> :error
  end

  @doc "What a checkout that no build has touched reports."
  @spec dev() :: t()
  def dev do
    %{version: "dev", revision: nil, built_at: nil, ci: nil}
  end

  @doc """
  Drops the cached value. The test suite calls this: `:persistent_term` is not
  rolled back with the database.
  """
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@term)
    :ok
  end

  defp from_json(%{} = decoded) do
    %{
      version: decoded["version"] || "dev",
      revision: blank_to_nil(decoded["revision"]),
      built_at: blank_to_nil(decoded["built_at"]),
      ci: from_json_ci(blank_to_nil(decoded["ci"]))
    }
  end

  # The file is JSON, the rest of the application reads maps with atom keys —
  # normalise here so nothing downstream has to remember which is which.
  defp from_json_ci(%{} = ci) do
    %{
      provider: blank_to_nil(ci["provider"]),
      workflow: blank_to_nil(ci["workflow"]),
      run_number: blank_to_nil(ci["run_number"]),
      run_url: blank_to_nil(ci["run_url"])
    }
  end

  defp from_json_ci(_ci), do: nil

  defp priv_dir do
    case :code.priv_dir(:confluence_phx_mirror) do
      {:error, _} -> nil
      dir -> List.to_string(dir)
    end
  end

  defp short(revision) when is_binary(revision), do: String.slice(revision, 0, 7)
  defp short(_revision), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(:null), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
