defmodule ConfluencePhxMirror.Confluence.TrafficSource do
  @moduledoc """
  Test double that reports a call the way `HttpSource` does.

  The demo snapshot never touches the network, so a run against it has nothing
  to summarise. This source makes the one call a real client would make to list
  spaces, which is enough for a test to see the run-end summary of its traffic.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.{DemoSource, Traffic}

  @impl true
  def spaces(opts) do
    Traffic.request(200, 12, 512)
    DemoSource.spaces(opts)
  end

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  defdelegate web_url(), to: DemoSource

  @impl true
  defdelegate pages(space_key, opts), to: DemoSource

  @impl true
  defdelegate page(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate comments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate restrictions(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate space_permissions(space_key, opts), to: DemoSource

  @impl true
  defdelegate group_members(group_name, opts), to: DemoSource

  @impl true
  defdelegate attachments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachment_data(attachment, opts), to: DemoSource

  @impl true
  defdelegate changed_since(since, opts), to: DemoSource
end
