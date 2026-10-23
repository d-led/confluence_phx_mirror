defmodule ConfluencePhxMirror.Sync.PageWorkerTest do
  @moduledoc """
  The webhook path: the job pulls the one page it names and leaves the audit
  trail saying who asked.

  The source is the bundled demo, so an id here is a page the mirror really
  knows; `SyncTest` covers what a page sync does to content.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.{PageWorker, SyncRun}

  test "a page is pulled on its own" do
    assert :ok = perform_job(PageWorker, %{"confluence_id" => 1002})

    assert last_run().status == "succeeded"
    assert started_entry(last_run()).metadata["mode"] == "page"
    assert {:ok, page} = Mirror.find_page(1002)
    assert page.title == "Architecture Overview"
  end

  test "an id that came back from JSON as a string is the same page" do
    assert :ok = perform_job(PageWorker, %{"confluence_id" => "1002"})

    assert {:ok, _page} = Mirror.find_page(1002)
  end

  test "the trigger names the webhook event in the audit trail" do
    assert :ok =
             perform_job(PageWorker, %{
               "confluence_id" => 1002,
               "trigger" => "the page_updated webhook"
             })

    assert finished_entry(last_run()).metadata["trigger"] == "the page_updated webhook"
  end

  test "without a trigger the audit names a webhook" do
    assert :ok = perform_job(PageWorker, %{"confluence_id" => 1002})

    assert finished_entry(last_run()).metadata["trigger"] == "a webhook"
  end

  test "a page the source cannot find fails the run, and raises for Oban to retry" do
    assert_raise RuntimeError, ~r/not_found/, fn ->
      perform_job(PageWorker, %{"confluence_id" => 999_999})
    end

    assert last_run().status == "failed"
  end

  defp last_run do
    Repo.one(from run in SyncRun, order_by: [desc: run.id], limit: 1)
  end

  defp started_entry(run) do
    Repo.one(
      from event in Event,
        where: event.action == "sync.started" and event.entity_id == ^to_string(run.id),
        order_by: [desc: event.id],
        limit: 1
    )
  end

  defp finished_entry(run) do
    Repo.one(
      from event in Event,
        where: event.action == "sync.finished" and event.entity_id == ^to_string(run.id),
        order_by: [desc: event.id],
        limit: 1
    )
  end
end
