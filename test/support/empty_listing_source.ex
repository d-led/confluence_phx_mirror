defmodule ConfluencePhxMirror.Confluence.EmptyListingSource do
  @moduledoc """
  Test double for a source that suddenly lists no pages for a space.

  Confluence does this when a token loses access or a space filter is
  misconfigured; the mirror must keep its content instead of treating the
  silence as a mass deletion.
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
  def pages(_space_key, _opts), do: {:ok, []}

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
