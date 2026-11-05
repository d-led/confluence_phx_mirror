defmodule ConfluencePhxMirrorWeb.SpaceResyncTest do
  @moduledoc """
  An administrator can ask the mirror to re-read one whole space — its pages and
  everything that hangs off them — from the space's own screen. A reader can
  neither see the control nor take the address behind it, and an administrator
  who is not offered it on some other space's page is not offered a surprise.

  The read happens in the background, so what a request can be held to is the job
  it queues and the screen it goes back to.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false
  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Sync.SpaceWorker

  setup %{conn: conn} do
    demo_snapshot!()
    {:ok, conn: log_in_admin(conn)}
  end

  test "an administrator's space offers a resync, and taking it queues a read of that space",
       %{conn: conn} do
    served = html_response(get(conn, space_path()), 200)
    document = LazyHTML.from_fragment(served)

    assert LazyHTML.query(document, resync_control()) |> Enum.count() == 1

    taken = conn |> post(resync_path()) |> redirected_to()

    assert taken == space_path()
    assert_enqueued(worker: SpaceWorker, args: %{"space_key" => "ENG"})
  end

  test "a page of the space that is not its home offers no space-wide press", %{conn: conn} do
    served = html_response(get(conn, other_page_path()), 200)
    document = LazyHTML.from_fragment(served)

    assert Enum.empty?(LazyHTML.query(document, resync_control()))
  end

  test "a reader is offered no resync and cannot take one", %{conn: _admin} do
    served = build_conn() |> get(space_path())
    document = LazyHTML.from_fragment(html_response(served, 200))

    assert Enum.empty?(LazyHTML.query(document, resync_control()))

    refused = served |> post(resync_path())
    assert html_response(refused, 404)
    refute_enqueued(worker: SpaceWorker)
  end

  defp space_path, do: URLs.space_path("ENG")

  defp other_page_path,
    do: URLs.page_path("ENG", Demo.open_page(), Demo.open_page_slug())

  defp resync_path, do: URLs.space_resync_path("ENG")

  # The action is a plain form: it must work on a page served from the cache, so
  # it carries a CSRF token and no LiveView wiring.
  defp resync_control, do: ~s(form[action="#{resync_path()}"][method="post"])
end
