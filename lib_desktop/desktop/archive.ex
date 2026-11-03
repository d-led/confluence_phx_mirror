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

  require Logger

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

  @doc """
  What the last publish did: `:idle`, `:publishing`, `{:done, at}` or
  `{:error, message}`.

  A failure is kept and shown, not just logged: a screen that goes back to
  "nothing to read yet" after a failed write tells a person their mirror is empty
  when it is not.
  """
  @spec publish_status() :: :idle | :publishing | {:done, DateTime.t()} | {:error, String.t()}
  def publish_status, do: :persistent_term.get({__MODULE__, :publish}, :idle)

  @doc """
  Writes the mirror as a folder of pages the tool can serve.

  The entries are the archive's own (`Site.archive/3`), written to disk instead
  of zipped: the window then reads the mirror over loopback, with the same
  links, search page and labels a downloaded copy has, and there is no second
  renderer to drift from the one that ships.

  Written into a staging folder and renamed into place, so a copy that fails
  halfway is never mistaken for one that finished.
  """
  @spec publish() :: :ok
  def publish do
    target = dir()
    staging = target <> ".building"

    File.rm_rf!(staging)
    File.mkdir_p!(staging)

    %Scope{admin?: true}
    |> Export.site_archive()
    |> Enum.each(fn
      {path, data, _at} -> write(staging, path, data)
      {path, data} -> write(staging, path, data)
    end)

    File.rm_rf!(target)
    File.rename!(staging, target)
    :ok
  end

  @doc """
  Starts writing the browsable copy, unless it is already being written.

  One writer at a time, because two would write the same files and the last one
  to finish would win — including when the loser was the one with the newer
  catalogue. A failure ends up in `status/0` and in the log, and the previous
  copy is left exactly as it was.
  """
  @spec publish_async() :: :started | :publishing
  def publish_async do
    if publish_status() == :publishing do
      :publishing
    else
      :persistent_term.put({__MODULE__, :publish}, :publishing)

      {:ok, _pid} =
        Task.Supervisor.start_child(ConfluencePhxMirror.Desktop.TaskSupervisor, fn ->
          status =
            try do
              publish()
              {:done, DateTime.utc_now()}
            rescue
              error -> failed(error)
            catch
              :exit, reason -> failed({:exit, reason})
            end

          :persistent_term.put({__MODULE__, :publish}, status)
        end)

      :started
    end
  end

  defp failed(reason) do
    message = format_reason(reason)
    Logger.error("writing the mirror failed: #{message}")
    {:error, message}
  end

  defp format_reason(%{__exception__: true} = error), do: Exception.message(error)
  defp format_reason(reason), do: inspect(reason)

  defp write(directory, path, data) do
    data = if is_function(data, 0), do: data.(), else: data
    target = Path.join(directory, path)

    File.mkdir_p!(Path.dirname(target))
    File.write!(target, return_to_the_tool(path, data))
  end

  # The pages the window serves are the exporter's, and their links are the
  # archive's: they know nothing about the tool that is showing them. A webview
  # has no address bar and no Back button, so without this every page of the
  # mirror is a page you cannot leave.
  #
  # Only the served copy gets it. The archive stays exactly what Confluence
  # exports, because a downloaded folder has no tool to return to.
  @return_bar """
  <a href="/" data-tool-return style="position:fixed;left:1rem;bottom:1rem;z-index:2147483647;padding:.5rem .85rem;border-radius:999px;border:1px solid color-mix(in srgb, CanvasText 30%, transparent);background:Canvas;color:CanvasText;font:600 13px/1 ui-sans-serif,-apple-system,'Segoe UI',Roboto,sans-serif;text-decoration:none;box-shadow:0 2px 10px rgba(0,0,0,.25)">\u2190 Back to the tool</a>
  """

  defp return_to_the_tool(path, html) when is_binary(html) do
    if String.ends_with?(path, ".html") do
      Regex.replace(~r/<body[^>]*>/i, html, "\\0" <> @return_bar, global: false)
    else
      html
    end
  end

  defp return_to_the_tool(_path, data), do: data

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
