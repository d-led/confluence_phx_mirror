defmodule ConfluencePhxMirror.Confluence.CancellingSource do
  @moduledoc """
  The demo snapshot, except that listing its spaces asks for the run to stop.

  A cancellation is something an administrator does while a sync is working, so
  a test needs a sync that is working: this source reports "someone asked" on
  the first call it makes, which is the first place the pipeline looks.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Confluence.DemoSource
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.SyncRun

  def spaces(opts) do
    request_cancellation()
    DemoSource.spaces(opts)
  end

  # The run is the newest `running` row: the source is called *by* the run it
  # has to stop, so there is exactly one.
  defp request_cancellation do
    run =
      Repo.one(
        from r in SyncRun,
          where: r.status == "running",
          order_by: [desc: r.id],
          limit: 1
      )

    if run, do: Sync.cancel(run.id, {:user, %{email: "admin@example.com"}})
  end

  defdelegate name(), to: DemoSource
  defdelegate kind(), to: DemoSource
  defdelegate pages(space_key, opts), to: DemoSource
  defdelegate page(confluence_id, opts), to: DemoSource
  defdelegate comments(confluence_id, opts), to: DemoSource
  defdelegate attachments(confluence_id, opts), to: DemoSource
  defdelegate attachment_data(attachment, opts), to: DemoSource
  defdelegate changed_since(since, opts), to: DemoSource
end
