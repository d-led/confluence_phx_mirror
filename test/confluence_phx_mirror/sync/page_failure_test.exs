defmodule ConfluencePhxMirror.Sync.PageFailureTest do
  @moduledoc """
  A page that goes wrong says which page.

  The details pass fans a run's pages out to tasks, and a task reports its
  outcome as a value — not as its identity. Two things follow, and both were
  wrong: a task that *died* left an error with no page on it (nothing to look
  at), and a stop that landed inside a task was counted as that page's failure
  instead of as the run ending.

  And the one failure that must never be softened: who may read a page. A source
  that cannot answer is not a source that answered "nobody in particular".
  """

  # The suite commits one copy of the demo site before the first test, and page
  # 1003 in it already carries its restriction — these tests are about what a run
  # does when that answer is *lost*, so they start from a mirror holding nothing.
  # Emptied inside the transaction, which is why this file is not async.
  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import Ecto.Query

  alias ConfluencePhxMirror.Confluence.DemoSource
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.SyncRun

  # The demo site, with the read-restriction call failing for every page.
  defmodule BlindSource do
    @moduledoc false
    @behaviour ConfluencePhxMirror.Confluence.Source

    defdelegate name(), to: DemoSource
    defdelegate kind(), to: DemoSource
    defdelegate spaces(opts), to: DemoSource
    defdelegate pages(space_key, opts), to: DemoSource
    defdelegate page(confluence_id, opts), to: DemoSource
    defdelegate comments(confluence_id, opts), to: DemoSource
    defdelegate attachments(confluence_id, opts), to: DemoSource
    defdelegate attachment_data(attachment, opts), to: DemoSource

    @impl true
    def restrictions(_confluence_id, _opts), do: {:error, :rate_limited}
  end

  # The demo site, with one page's comments call raising rather than answering.
  defmodule ExplodingSource do
    @moduledoc false
    @behaviour ConfluencePhxMirror.Confluence.Source

    defdelegate name(), to: DemoSource
    defdelegate kind(), to: DemoSource
    defdelegate spaces(opts), to: DemoSource
    defdelegate pages(space_key, opts), to: DemoSource
    defdelegate page(confluence_id, opts), to: DemoSource
    defdelegate attachments(confluence_id, opts), to: DemoSource
    defdelegate attachment_data(attachment, opts), to: DemoSource
    defdelegate restrictions(confluence_id, opts), to: DemoSource

    @impl true
    def comments(confluence_id, _opts) when confluence_id in [1003, "1003"],
      do: raise("the comments call came apart")

    def comments(confluence_id, opts), do: DemoSource.comments(confluence_id, opts)
  end

  # The demo site, with the stop asked for from another node: the row is marked,
  # no process is killed, and the pipeline is the thing that notices.
  defmodule StoppedElsewhereSource do
    @moduledoc false
    @behaviour ConfluencePhxMirror.Confluence.Source

    defdelegate name(), to: DemoSource
    defdelegate kind(), to: DemoSource
    defdelegate spaces(opts), to: DemoSource
    defdelegate pages(space_key, opts), to: DemoSource
    defdelegate page(confluence_id, opts), to: DemoSource
    defdelegate attachments(confluence_id, opts), to: DemoSource
    defdelegate attachment_data(attachment, opts), to: DemoSource
    defdelegate restrictions(confluence_id, opts), to: DemoSource

    @impl true
    def comments(confluence_id, opts) do
      ask_for_a_stop()
      DemoSource.comments(confluence_id, opts)
    end

    defp ask_for_a_stop do
      run =
        Repo.one(
          from(r in SyncRun,
            where: r.status == "running" and is_nil(r.cancel_requested_at),
            order_by: [desc: r.id],
            limit: 1
          )
        )

      if run do
        run
        |> SyncRun.changeset(%{cancel_requested_at: DateTime.utc_now()})
        |> Repo.update!()
      end
    end
  end

  describe "the answer to \"who may read this page\"" do
    test "a page that could not be asked about is left without details, and stays due" do
      {:ok, run} = Sync.run(:page, confluence_id: 1003, source: BlindSource)

      assert run.status == "partial"
      assert Enum.any?(errors_of(run), &(&1["id"] == 1003))
      assert hd(errors_of(run))["reason"] =~ "rate_limited"

      # Nothing about who may read it was written, and the details that decide
      # that were not written either — so the page has no body to show and the
      # next run reads it again, instead of it being finished as an open page.
      assert Mirror.page_restrictions(1003) == []
      assert {:ok, page} = Mirror.find_page(1003)
      assert page.details_synced_at == nil
    end

    test "a page already mirrored keeps the restrictions it had" do
      {:ok, _first} = Sync.run(:page, confluence_id: 1003)
      assert Mirror.page_restrictions(1003) != []

      {:ok, run} = Sync.run(:page, confluence_id: 1003, source: BlindSource)

      assert run.status == "partial"
      assert Mirror.page_restrictions(1003) != []
    end
  end

  describe "a page that goes wrong" do
    test "names itself, keeps its frames, and the run carries on" do
      {:ok, run} = Sync.run(:page, confluence_id: 1003, source: ExplodingSource)

      assert run.status == "partial"

      assert [%{"scope" => "page", "id" => 1003} = failure] = errors_of(run)
      assert failure["reason"] =~ "the comments call came apart"
      assert failure["trace"] =~ "ConfluencePhxMirror.Sync"
    end

    test "is not blamed for a stop that landed in it" do
      {:ok, run} = Sync.run(:page, confluence_id: 1003, source: StoppedElsewhereSource)

      assert run.status == "cancelled"
      assert run.error =~ "stopped on request"
      assert errors_of(run) == []
    end
  end

  defp errors_of(run), do: run.stats["errors"] || []
end
