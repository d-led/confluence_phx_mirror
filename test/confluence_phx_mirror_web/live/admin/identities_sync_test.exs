defmodule ConfluencePhxMirrorWeb.Live.AdminIdentitiesSyncTest do
  @moduledoc """
  "Sync with Confluence" on the identities screen: it asks the site again who is
  in which group, without reading a page — and it says that it runs in the
  background rather than pretending the answer is already there.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Sync.PeopleWorker

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops-identities@example.com", role: "admin"})

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "the button queues a people run and links to the job", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/identities")

    view |> element("#sync-identities") |> render_click()

    assert has_element?(view, "#identities-job-queued")
    assert has_element?(view, ~s(#identities-job-queued-link[href^="/admin/jobs#job-"]))
    assert_enqueued(worker: PeopleWorker)
  end
end
