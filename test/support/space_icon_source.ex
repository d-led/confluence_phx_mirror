defmodule ConfluencePhxMirror.Confluence.SpaceIconSource do
  @moduledoc """
  The demo snapshot, with an icon for every space.

  There is no site behind the demo fixture, so the bytes are generated from the
  icon path. The source also tells the process that asked it (`listen/1`) what
  it was asked to fetch, which is how a test says "the second sync did not
  download anything again".

  Neither the listener nor the failure is process state: the sync reads its
  source from a child of its caller (see `Sync.run_work/4`), so a fixture that
  reported to `self()` would be talking to the wrong process.
  """

  alias ConfluencePhxMirror.Confluence.DemoSource

  @failure_key {__MODULE__, :failure}
  @listener_key {__MODULE__, :listener}

  @doc "Tells `pid` what this source was asked for. Cleared by `reset/0`."
  def listen(pid), do: :persistent_term.put(@listener_key, pid)

  @doc "Makes every following icon fetch fail with `reason`."
  def fail_with(reason), do: :persistent_term.put(@failure_key, reason)

  @doc "Forgets the listener and the failure."
  def reset do
    :persistent_term.erase(@listener_key)
    :persistent_term.erase(@failure_key)
  end

  @doc "The bytes this source serves for one icon path."
  def icon_bytes(path) do
    ~s(<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48"><title>#{path}</title></svg>)
  end

  def spaces(opts) do
    with {:ok, spaces} <- DemoSource.spaces(opts) do
      {:ok, Enum.map(spaces, &Map.put(&1, :icon, %{path: icon_path(&1.key)}))}
    end
  end

  def space_icon(%{path: path}, _opts) do
    send(listener(), {:space_icon, path})

    case :persistent_term.get(@failure_key, nil) do
      nil -> {:ok, %{body: icon_bytes(path), media_type: "image/svg+xml"}}
      reason -> {:error, reason}
    end
  end

  defp listener, do: :persistent_term.get(@listener_key, self())

  defp icon_path(space_key), do: "/download/attachments/#{String.downcase(space_key)}/icon"

  defdelegate name(), to: DemoSource
  defdelegate kind(), to: DemoSource
  defdelegate pages(space_key, opts), to: DemoSource
  defdelegate page(confluence_id, opts), to: DemoSource
  defdelegate comments(confluence_id, opts), to: DemoSource
  defdelegate attachments(confluence_id, opts), to: DemoSource
  defdelegate attachment_data(attachment, opts), to: DemoSource
  defdelegate changed_since(since, opts), to: DemoSource
end
