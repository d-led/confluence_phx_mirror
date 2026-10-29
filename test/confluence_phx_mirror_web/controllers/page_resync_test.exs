defmodule ConfluencePhxMirrorWeb.PageResyncTest do
  @moduledoc """
  An administrator can ask the mirror to re-read one page — its body, its
  attachments and its comments, everything that hangs off it — without waiting
  for the next full sync. A reader cannot: the page they are served carries no
  such control, and the address behind it answers them the way an unknown page
  does.

  The read happens in the background, so what a request can be held to is the
  job it queues and the page it goes back to, not the read itself.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false
  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Sync.PageWorker

  setup %{conn: conn} do
    demo_snapshot!()
    {:ok, conn: log_in_admin(conn)}
  end

  test "an administrator's page offers a resync, and taking it queues a fresh read of that page",
       %{conn: conn} do
    reader_conn = conn |> get(page_path())
    reader_page = LazyHTML.from_fragment(html_response(reader_conn, 200))

    assert LazyHTML.query(reader_page, resync_control()) |> Enum.count() == 1

    taken =
      reader_conn
      |> post(resync_path())
      |> redirected_to()

    assert taken == page_path()

    # `force` is the promise the button makes: a page the sync would otherwise
    # leave alone — a live doc read a minute ago — is read now.
    assert_enqueued(
      worker: PageWorker,
      args: %{"confluence_id" => Demo.open_page_number(), "force" => true}
    )
  end

  test "a reader is offered no resync and cannot take one", %{conn: _admin} do
    served = build_conn() |> get(page_path())
    document = LazyHTML.from_fragment(html_response(served, 200))

    assert Enum.empty?(LazyHTML.query(document, resync_control()))

    refused = served |> post(resync_path())
    assert html_response(refused, 404)
    refute_enqueued(worker: PageWorker)
  end

  defp page_path, do: URLs.page_path("ENG", Demo.open_page(), Demo.open_page_slug())

  defp resync_path, do: URLs.page_resync_path("ENG", Demo.open_page())

  # The action is a plain form: it must work on a page served from the cache,
  # so it carries a CSRF token and no LiveView wiring.
  defp resync_control, do: ~s(form[action="#{resync_path()}"][method="post"])
end
