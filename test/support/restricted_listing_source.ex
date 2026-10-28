defmodule ConfluencePhxMirror.Confluence.RestrictedListingSource do
  @moduledoc """
  Test double for a token that still reaches the site but no longer sees most of
  a space — a page restriction added for the sync account, or a group it lost.

  Every page it hides is one the site still has, so anything the mirror does on
  the strength of this listing (other than flagging it for review) is a bug:

      TestConfig.put(RestrictedListingSource, restricted: ["ENG"])

  Answers like the demo source; the restricted spaces list a single page.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  defdelegate spaces(opts), to: DemoSource

  @impl true
  def pages(space_key, opts) do
    {:ok, dtos} = DemoSource.pages(space_key, opts)

    if space_key in restricted(), do: {:ok, Enum.take(dtos, 1)}, else: {:ok, dtos}
  end

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

  defp restricted do
    :confluence_phx_mirror
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:restricted, [])
  end
end
