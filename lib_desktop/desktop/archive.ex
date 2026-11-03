defmodule ConfluencePhxMirror.Desktop.Archive do
  @moduledoc """
  The mirror as a folder a person can keep.

  Everything that turns rows into pages, Markdown, attachments and a search page
  is the server's exporter, called unchanged: `Export.site_archive/1` reads every
  space in this catalogue and `Export.Zip` streams the result. What is added here
  is the part a tool has to decide and a deployment does not — one build at a
  time, written to a file before anyone downloads it, so a copy that takes
  minutes is fetched once and kept.

  The file lands under the workspace's own folder, beside the catalogue it
  copies, because that is the folder the home screen already names. The build
  itself belongs to `ConfluencePhxMirror.Export.Artifact`: it holds the only
  build, reports how many bytes are on disk, and hands back a file with a length
  rather than a stream that has to be regenerated to be resumed.
  """

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Desktop.Settings
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Export.{Artifact, Zip}

  @by "this tool"

  @doc """
  Starts building the archive unless it is ready, already building, or
  impossible.

  `:ready` means the file in hand was built from the content in force: anything
  mirrored since is a rebuild, because an archive that no longer matches the
  catalogue is worse than a wait.
  """
  @spec prepare() :: :started | :ready | {:busy, String.t() | nil}
  def prepare do
    Artifact.prepare(Export.site_artifact(),
      by: @by,
      version: Export.site_archive_version(),
      build: &build/1
    )
  end

  @doc "What is happening to the archive, as `ConfluencePhxMirror.Export.Artifact` reports it."
  @spec status() :: :absent | {:building, map()} | {:ready, map()}
  def status, do: Artifact.status(Export.site_artifact())

  @doc "Where the archive is written."
  @spec path() :: Path.t()
  def path, do: Artifact.path(Export.site_artifact())

  @doc "The folder the browsable copy is written to."
  @spec dir() :: Path.t()
  def dir, do: Path.join(Settings.root(), "site")

  @doc "Whether a browsable copy exists."
  @spec published?() :: boolean()
  def published?, do: File.exists?(Path.join(dir(), "index.html"))

  @doc "Whether the copy is being written right now."
  @spec publishing?() :: boolean()
  def publishing?, do: :persistent_term.get({__MODULE__, :publishing}, false)

  @doc """
  Writes the mirror as a folder of pages the tool can serve.

  The entries are the archive's own (`Site.archive/3`), written to disk instead
  of zipped: the window then reads the mirror over loopback, with the same
  links, search page and labels a downloaded copy has, and there is no second
  renderer to drift from the one that ships.
  """
  @spec publish() :: :ok
  def publish do
    directory = dir()

    File.rm_rf!(directory)
    File.mkdir_p!(directory)

    %Scope{admin?: true}
    |> Export.site_archive()
    |> Enum.each(fn
      {path, data, _at} -> write(directory, path, data)
      {path, data} -> write(directory, path, data)
    end)

    :ok
  end

  @doc """
  Starts writing the browsable copy, unless it is already being written.

  One writer at a time, because two would write the same files and the last one
  to finish would win — including when the loser was the one with the newer
  catalogue.
  """
  @spec publish_async() :: :started | :publishing
  def publish_async do
    if publishing?() do
      :publishing
    else
      :persistent_term.put({__MODULE__, :publishing}, true)

      {:ok, _pid} =
        Task.Supervisor.start_child(ConfluencePhxMirror.Desktop.TaskSupervisor, fn ->
          try do
            publish()
          after
            :persistent_term.put({__MODULE__, :publishing}, false)
          end
        end)

      :started
    end
  end

  defp write(directory, path, data) do
    data = if is_function(data, 0), do: data.(), else: data
    target = Path.join(directory, path)

    File.mkdir_p!(Path.dirname(target))
    File.write!(target, data)
  end

  # The tool has one reader and no authorisation model of its own: everything in
  # its catalogue is theirs, which is what the server's exporter calls an
  # administrator. There is no request to take a scope from.
  defp build(emit) do
    %Scope{admin?: true}
    |> Export.site_archive()
    |> Zip.chunks()
    |> Enum.each(fn chunk -> emit.(IO.iodata_to_binary(chunk)) end)
  end
end
