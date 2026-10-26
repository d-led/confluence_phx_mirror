defmodule ConfluencePhxMirror.CountLessSource do
  @moduledoc """
  A source that cannot answer "how much do you hold?" but can name its ids.

  Confluence itself always can, but a source does not have to: `counts/2` is an
  optional callback, and a verify pass must still work without it — by listing
  the space instead of trusting a count.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @impl true
  def page_ids(_space_key, _opts) do
    # Stands in for a site that holds one of the two pages a test builds.
    {:ok, %{page: [1001], blogpost: []}}
  end

  @impl true
  def name, do: "count-less"

  @impl true
  def kind, do: :demo

  @impl true
  def web_url, do: nil

  @impl true
  def spaces(opts), do: DemoSource.spaces(opts)

  @impl true
  def pages(space_key, opts), do: DemoSource.pages(space_key, opts)

  @impl true
  def page(confluence_id, opts), do: DemoSource.page(confluence_id, opts)

  @impl true
  def comments(confluence_id, opts), do: DemoSource.comments(confluence_id, opts)

  @impl true
  def attachments(confluence_id, opts), do: DemoSource.attachments(confluence_id, opts)

  @impl true
  def attachment_data(attachment, opts), do: DemoSource.attachment_data(attachment, opts)
end
