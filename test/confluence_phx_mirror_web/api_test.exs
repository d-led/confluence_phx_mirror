defmodule ConfluencePhxMirrorWeb.ApiTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts

  setup do
    demo_snapshot!()
    :ok
  end

  describe "GET /api/v1" do
    test "lists spaces with page counts", %{conn: conn} do
      body = conn |> get(~p"/api/v1/spaces") |> json_response(200)

      eng = Enum.find(body["results"], &(&1["key"] == "ENG"))
      assert eng["name"] == "Engineering Handbook"
      assert eng["pageCount"] == 10
    end

    test "returns a page with both bodies and labels", %{conn: conn} do
      page = conn |> get(~p"/api/v1/pages/1002") |> json_response(200)

      assert page["id"] == "1002"
      assert page["title"] == "Architecture Overview"
      assert page["body"]["storage"]["representation"] == "storage"
      assert page["body"]["export_view"]["value"] =~ "poll → render"
      assert %{"name" => "architecture"} = hd(page["metadata"]["labels"]["results"])
      assert page["mirror"]["syncedAt"]
      assert page["_links"]["original"] =~ "demo.atlassian.net"
    end

    test "lists children, labels, attachments and comments", %{conn: conn} do
      children = conn |> get(~p"/api/v1/pages/1001/children") |> json_response(200)
      assert Enum.any?(children["results"], &(&1["title"] == "Architecture Overview"))

      labels = conn |> get(~p"/api/v1/pages/1002/labels") |> json_response(200)
      assert Enum.map(labels["results"], & &1["name"]) == ["architecture", "design"]

      attachments = conn |> get(~p"/api/v1/pages/1002/attachments") |> json_response(200)
      diagram = Enum.find(attachments["results"], &(&1["title"] == "diagram.svg"))
      assert diagram["extensions"]["mediaType"] == "image/svg+xml"
      assert diagram["_links"]["download"] == "/attachments/ENG/1002/9001/diagram.svg"

      comments = conn |> get(~p"/api/v1/pages/1001/comments") |> json_response(200)
      assert comments["size"] == 2
    end

    test "searches text by default across all fields", %{conn: conn} do
      body = conn |> get(~p"/api/v1/search?q=rate+limit") |> json_response(200)

      assert body["filters"]["q"] == "rate limit"
      assert [%{"title" => "Search and CQL"} | _] = body["results"]
      assert hd(body["results"])["rank"] > 0
    end

    test "filters by space and label without exposing CQL", %{conn: conn} do
      body = conn |> get(~p"/api/v1/search?space=ENG&label=architecture") |> json_response(200)

      assert body["filters"] == %{"space" => "ENG", "label" => "architecture"}
      assert [%{"title" => "Architecture Overview"}] = body["results"]
    end

    test "combines text with structured filters", %{conn: conn} do
      body = conn |> get(~p"/api/v1/search?q=pipeline&space=ENG") |> json_response(200)

      assert Enum.any?(body["results"], &(&1["title"] == "Architecture Overview"))
      refute Enum.any?(body["results"], &(&1["title"] == "Release 2.0"))
    end

    test "rejects a search without any criteria", %{conn: conn} do
      body = conn |> get(~p"/api/v1/search") |> json_response(400)
      assert body["error"] == "missing_query"
    end

    test "exposes stats and freshness", %{conn: conn} do
      body = conn |> get(~p"/api/v1/stats") |> json_response(200)
      assert body["stats"]["pages"] == 13
      assert body["lastSync"]["status"] == "succeeded"
    end
  end

  describe "Confluence-compatible routes" do
    test "content list and single content", %{conn: conn} do
      list = conn |> get(~p"/wiki/rest/api/content?spaceKey=ENG&limit=5") |> json_response(200)
      assert list["size"] == 5
      assert list["limit"] == 5
      assert list["results"] |> hd() |> Map.has_key?("_links")

      page = conn |> get(~p"/wiki/rest/api/content/1002") |> json_response(200)
      assert page["id"] == "1002"
      assert page["space"]["key"] == "ENG"
      assert page["version"]["number"] == 15
    end

    test "content search uses the same CQL engine", %{conn: conn} do
      body =
        conn
        |> get(~p"/wiki/rest/api/content/search?cql=type = blogpost")
        |> json_response(200)

      assert Enum.map(body["results"], & &1["title"]) == ["Release 2.0"]
    end
  end

  describe "authentication" do
    test "accepts a bearer token", %{conn: _conn} do
      user = user_fixture(%{email: "api-reader@example.com"})
      {:ok, plain, _token} = Accounts.create_api_token(user, "test", {:system, "test"})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{plain}")
        |> get(~p"/api/v1/pages/1002")

      assert json_response(conn, 200)["title"] == "Architecture Overview"
    end

    test "rejects an invalid token", %{conn: _conn} do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer nope")
        |> get(~p"/api/v1/pages/1002")

      assert json_response(conn, 401)["error"] == "invalid_token"
    end
  end

  describe "reader rate limiting" do
    test "returns 429 with Retry-After once the API budget is spent", %{conn: _conn} do
      original = Application.get_env(:confluence_phx_mirror, :reader_rate_limit)

      Application.put_env(:confluence_phx_mirror, :reader_rate_limit,
        enabled: true,
        html: [limit: 1_000, period_ms: 60_000],
        api: [limit: 1, period_ms: 60_000],
        attachments: [limit: 1_000, period_ms: 60_000]
      )

      on_exit(fn -> Application.put_env(:confluence_phx_mirror, :reader_rate_limit, original) end)

      user = user_fixture(%{email: "rate-limited@example.com"})
      {:ok, plain, _} = Accounts.create_api_token(user, "rate", {:system, "test"})
      header = {"authorization", "Bearer #{plain}"}

      first =
        build_conn() |> put_req_header(elem(header, 0), elem(header, 1)) |> get(~p"/api/v1/stats")

      assert first.status == 200
      assert get_resp_header(first, "x-ratelimit-limit") == ["1"]
      assert get_resp_header(first, "x-ratelimit-remaining") == ["0"]

      second =
        build_conn() |> put_req_header(elem(header, 0), elem(header, 1)) |> get(~p"/api/v1/stats")

      assert second.status == 429
      assert get_resp_header(second, "retry-after") != []
    end
  end
end
