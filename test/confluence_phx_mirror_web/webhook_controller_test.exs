defmodule ConfluencePhxMirrorWeb.WebhookControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Settings
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

  test "an unsigned delivery is accepted and marked unverified", %{conn: conn} do
    body = JSON.encode!(payload("page_updated", 1002))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/confluence", body)

    assert json_response(conn, 202)["status"] == "accepted"
    refute Repo.one!(Delivery).signature_valid
    assert_enqueued(worker: PageWorker, args: %{"confluence_id" => 1002})
  end

  test "refuses a body larger than a delivery should be", %{conn: conn} do
    body = JSON.encode!(%{"event" => "page_updated", "page" => %{"id" => "1002"}})
    body = body <> String.duplicate(" ", 1_048_576)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/confluence", body)

    assert json_response(conn, 413)["error"] == "payload_too_large"
    assert Repo.aggregate(Delivery, :count) == 0
  end

  describe "when signatures are required" do
    setup do
      previous = Application.get_env(:confluence_phx_mirror, :webhooks)

      Application.put_env(:confluence_phx_mirror, :webhooks,
        secret: @secret,
        require_signature: true
      )

      on_exit(fn -> Application.put_env(:confluence_phx_mirror, :webhooks, previous) end)
      :ok
    end

    test "an unsigned delivery is refused", %{conn: conn} do
      body = JSON.encode!(payload("page_updated", 1002))

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/confluence", body)

      assert json_response(conn, 401)["error"] == "invalid_signature"
      assert Repo.one!(Delivery).status == "rejected"
      refute_enqueued(worker: PageWorker)
    end
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
    assert body["pages"] == 40
  end

  describe "route tokens" do
    setup do
      previous = Application.get_env(:confluence_phx_mirror, :webhook_tokens)

      Application.put_env(:confluence_phx_mirror, :webhook_tokens, %{
        "confluence" => "route-token"
      })

      on_exit(fn ->
        Application.put_env(:confluence_phx_mirror, :webhook_tokens, previous || %{})
      end)

      :ok
    end

    test "a configured token replaces the signature", %{conn: conn} do
      body = JSON.encode!(payload("page_updated", 1002))

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-webhook-token", "route-token")
        |> post(~p"/webhooks/confluence", body)

      assert json_response(conn, 202)["status"] == "accepted"
      assert_enqueued(worker: PageWorker, args: %{"confluence_id" => 1002})
    end

    test "a bearer token authenticates the delivery too", %{conn: conn} do
      body = JSON.encode!(payload("page_updated", 1002))

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer route-token")
        |> post(~p"/webhooks/confluence", body)

      assert json_response(conn, 202)["status"] == "accepted"
    end

    test "a wrong token is rejected before anything is processed", %{conn: conn} do
      body = JSON.encode!(payload("page_updated", 1002))

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-webhook-token", "not-the-token")
        |> post(~p"/webhooks/confluence", body)

      assert json_response(conn, 401)["error"] == "invalid_webhook_token"
      refute_enqueued(worker: PageWorker)
    end
  end

  describe "metering the intake" do
    setup do
      previous = Application.get_env(:confluence_phx_mirror, :webhook_rate_limit)

      Application.put_env(:confluence_phx_mirror, :webhook_rate_limit,
        limit: 2,
        period_ms: 60_000
      )

      on_exit(fn ->
        Application.put_env(:confluence_phx_mirror, :webhook_rate_limit, previous)
      end)

      :ok
    end

    test "unsigned deliveries are capped, and the ones accepted stay auditable", %{conn: _conn} do
      body = JSON.encode!(payload("page_updated", 1002))
      # Its own address, so the case does not share a bucket with the other
      # deliveries this file makes.
      caller = unique_address()

      assert post_unsigned(caller, body).status == 202
      assert post_unsigned(caller, body).status == 202
      assert post_unsigned(caller, body).status == 429

      assert Repo.aggregate(Delivery, :count) == 2
    end

    test "an administrator's cap overrides the configured one without a restart", %{conn: _conn} do
      # The describe configures two a minute; the page sets one.
      assert {:ok, _applied} = Settings.put_webhook_rate_limit(1, {:system, "test"})
      body = JSON.encode!(payload("page_updated", 1002))
      caller = unique_address()

      assert post_unsigned(caller, body).status == 202
      assert post_unsigned(caller, body).status == 429
    end

    # A bucket is keyed by address and lives in ETS for a minute, which outlives
    # the test that made it: two cases that both count deliveries need two
    # addresses that are never reused, so the counter spans two octets.
    defp unique_address do
      n = System.unique_integer([:positive, :monotonic])
      {198, 18, rem(n, 250) + 1, rem(div(n, 250), 250) + 1}
    end

    defp post_unsigned(address, body) do
      build_conn()
      |> Map.put(:remote_ip, address)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/confluence", body)
    end
  end

  describe "when the intake is switched off" do
    setup do
      previous = Application.get_env(:confluence_phx_mirror, :webhooks)

      Application.put_env(:confluence_phx_mirror, :webhooks,
        secret: @secret,
        enabled: false
      )

      on_exit(fn -> Application.put_env(:confluence_phx_mirror, :webhooks, previous) end)
      :ok
    end

    test "a delivery is answered exactly like a path that does not exist", %{conn: conn} do
      body = JSON.encode!(payload("page_updated", 1002))

      answered =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", sign(body))
        |> post(~p"/webhooks/confluence", body)

      nowhere =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/nothing", body)

      assert answered.status == 404
      assert answered.resp_body == nowhere.resp_body
      assert Repo.aggregate(Delivery, :count) == 0
      refute_enqueued(worker: PageWorker)
    end
  end
end
