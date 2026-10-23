defmodule ConfluencePhxMirror.Confluence.SpaceDroppingSource do
  @moduledoc """
  Test double for a site where a space was deleted between two snapshots.

  Answers like the demo source, minus the space keys the test names under this
  module:

      Application.put_env(:confluence_phx_mirror, #{inspect(__MODULE__)}, drop: ["PROD"])

  Everything else — pages, comments, attachments — is the demo snapshot's.
  """
  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  def spaces(opts) do
    dropped =
      :confluence_phx_mirror |> Application.get_env(__MODULE__, []) |> Keyword.get(:drop, [])

    {:ok, dtos} = DemoSource.spaces(opts)
    {:ok, Enum.reject(dtos, &(&1.key in dropped))}
  end

  @impl true
  defdelegate pages(space_key, opts), to: DemoSource

  @impl true
  defdelegate page(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate comments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachment_data(attachment, opts), to: DemoSource

  @impl true
  defdelegate changed_since(since, opts), to: DemoSource
end
