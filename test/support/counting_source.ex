defmodule ConfluencePhxMirror.Confluence.CountingSource do
  @moduledoc """
  The demo site with one page edited, reporting every page read it serves.

  A live doc must cost no request while the mirror's copy is young, and "no
  request" is something only the source can witness. The read is reported to the
  process named in `:report_reads_to`, because a sync does not run in the test's
  own process: the test starts a run and then asserts what it was told.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource
  alias ConfluencePhxMirror.Confluence.EditedSource

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  defdelegate spaces(opts), to: DemoSource

  @impl true
  defdelegate pages(space_key, opts), to: DemoSource

  @impl true
  defdelegate comments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachment_data(attachment, opts), to: DemoSource

  @impl true
  defdelegate changed_since(since, opts), to: DemoSource

  @impl true
  def page(confluence_id, opts) do
    if pid = Keyword.get(opts, :report_reads_to), do: send(pid, {:page_read, confluence_id})
    EditedSource.page(confluence_id, opts)
  end
end
