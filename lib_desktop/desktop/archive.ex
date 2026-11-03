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
