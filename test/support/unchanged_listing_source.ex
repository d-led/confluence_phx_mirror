defmodule ConfluencePhxMirror.Confluence.UnchangedListingSource do
  @moduledoc """
  Lists one page in the window and changes nothing about it.

  This is what the run table shows as "1 listed, 1 unchanged" when nothing has
  happened on the site: the page is inside the lookback window and the mirror
  already holds it, so the run has nothing to fetch and must say why.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @page_id 1002

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  defdelegate spaces(opts), to: DemoSource

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
  defdelegate restrictions(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate space_permissions(space_key, opts), to: DemoSource

  @impl true
  defdelegate group_members(group_name, opts), to: DemoSource

  @impl true
  defdelegate user_status(account_id, opts), to: DemoSource

  @impl true
  def changed_since(_since, _opts) do
    {:ok, [unchanged_page()]}
  end

  defp unchanged_page do
    {:ok, page} = DemoSource.page(@page_id, [])
    page
  end
end
