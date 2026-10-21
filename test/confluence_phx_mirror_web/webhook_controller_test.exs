defmodule ConfluencePhxMirrorWeb.WebhookControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.PageWorker
  alias ConfluencePhxMirror.Webhooks.Delivery

  @secret "test-webhook-secret"

  defp sign(body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @secret, body), case: :lower)

  defp payload(event, page_id) do
    %{"event" => event, "page" => %{"id" => to_string(page_id)}}
  end

  setup do
    demo_snapshot!()
    :ok
  end

  test "accepts a correctly signed delivery", %{conn: conn} do
    body = JSON.encode!(payload("page_updated", 1002))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", sign(body))
      |> post(~p"/webhooks/confluence", body)

    assert json_response(conn, 202)["status"] == "accepted"
    assert Repo.one!(Delivery).status == "queued"
    assert_enqueued(worker: PageWorker, args: %{"confluence_id" => 1002})
  end

  test "rejects a bad signature with 401 and stores the delivery", %{conn: conn} do
    body = JSON.encode!(payload("page_updated", 1002))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", "sha256=deadbeef")
      |> post(~p"/webhooks/confluence", body)

    assert json_response(conn, 401)["error"] == "invalid_signature"
    assert Repo.one!(Delivery).status == "rejected"
  end

  test "rejects an unsigned delivery", %{conn: conn} do
    body = JSON.encode!(payload("page_updated", 1002))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/confluence", body)

    assert json_response(conn, 401)["error"] == "invalid_signature"
  end

  test "page_removed marks the page deleted", %{conn: conn} do
    body = JSON.encode!(payload("page_removed", 1002))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", sign(body))
      |> post(~p"/webhooks/confluence", body)

    assert json_response(conn, 202)["state"] == "processed"
    assert ConfluencePhxMirror.Mirror.find_page(1002) == {:error, :not_found}
  end

  test "health endpoint reports database and content", %{conn: conn} do
    body = conn |> get(~p"/health") |> json_response(200)
    assert body["status"] == "ok"
    assert body["database"] == "ok"
    assert body["pages"] == 13
  end
end
