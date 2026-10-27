defmodule ConfluencePhxMirrorWeb.McpProtocolTest do
  @moduledoc """
  The endpoint over HTTP: the JSON-RPC lifecycle, the transport's rules, and the
  three ways a caller can be authenticated.

  The tool answers themselves are pinned in `ConfluencePhxMirror.Mcp.ToolsTest`;
  this file is about the wire — what a client sees before and around a tool call.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.UserPolicy.NewUsersCanReadPublicSpaces
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mcp.Tools

  @settings [:auto_admin, :proxy_auth, :proxy_auth_members_only, :user_policy, :self_signup]

  setup %{conn: conn} do
    previous = Map.new(@settings, &{&1, Application.fetch_env(:confluence_phx_mirror, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :error} -> Application.delete_env(:confluence_phx_mirror, key)
        {key, {:ok, value}} -> Application.put_env(:confluence_phx_mirror, key, value)
      end)
    end)

    # The lifecycle, the tools and the transport are exercised by a caller who
    # may do them; `describe "authentication"` starts from nobody instead.
    {:ok, conn: log_in_admin(conn)}
  end

  describe "initialize" do
    test "answers with the requested revision, the tools capability and instructions",
         %{conn: conn} do
      body =
        conn
        |> rpc("initialize", %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        })
        |> json_response(200)

      assert body["result"]["protocolVersion"] == "2025-06-18"
      assert body["result"]["capabilities"] == %{"tools" => %{"listChanged" => false}}
      assert body["result"]["serverInfo"]["name"] == "confluence-mirror"
      assert body["result"]["instructions"] =~ "read-only"
    end

    test "answers an unknown revision with the newest the mirror speaks", %{conn: conn} do
      body = conn |> rpc("initialize", %{"protocolVersion" => "2099-01-01"}) |> json_response(200)

      assert body["result"]["protocolVersion"] ==
               ConfluencePhxMirror.Mcp.latest_protocol_version()
    end

    test "the initialized notification is accepted with no body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/mcp",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
        )

      assert response(conn, 202) == ""
    end
  end

  describe "tools" do
    test "tools/list names every defined tool and every one is read-only", %{conn: conn} do
      body = conn |> rpc("tools/list") |> json_response(200)
      tools = body["result"]["tools"]

      assert Enum.map(tools, & &1["name"]) == Tools.names()
      assert Enum.all?(tools, &(&1["annotations"]["readOnlyHint"] == true))
      assert Enum.all?(tools, &(&1["inputSchema"]["type"] == "object"))
    end

    test "each tool says whether it is portable to mcp-atlassian", %{conn: conn} do
      tools = conn |> rpc("tools/list") |> json_response(200) |> get_in(["result", "tools"])

      ported = published_by(tools, "atlassian")
      own = published_by(tools, "mirror")

      assert Enum.sort(ported) == Enum.sort(Tools.atlassian_tools())
      assert "confluence_advanced_search" in own
      assert Enum.sort(ported ++ own) == Enum.sort(Tools.names())

      descriptions =
        for %{"name" => name, "description" => description} <- tools, name in own, do: description

      assert Enum.all?(descriptions, &String.starts_with?(&1, "Mirror-only"))
    end

    test "the two recency tools name each other, so a model cannot confuse them",
         %{conn: conn} do
      tools = conn |> rpc("tools/list") |> json_response(200) |> get_in(["result", "tools"])
      by_name = Map.new(tools, &{&1["name"], &1})

      assert by_name["confluence_index_status"]["title"] =~ "last spaces indexed"
      assert by_name["confluence_index_status"]["description"] =~ "confluence_get_recent_changes"
      assert by_name["confluence_get_recent_changes"]["description"] =~ "confluence_index_status"
    end

    test "tools/call answers with text and structured content", %{conn: conn} do
      demo_snapshot!()

      body =
        conn
        |> tool("confluence_get_page", %{"page_id" => Demo.open_page()})
        |> json_response(200)

      [content] = body["result"]["content"]
      assert content["type"] == "text"
      assert content["text"] =~ "# Architecture Overview"
      assert body["result"]["isError"] == false
      assert body["result"]["structuredContent"]["id"] == Demo.open_page()
    end

    test "a page the reader may not open is a tool error, not a protocol error", %{conn: conn} do
      demo_snapshot!()
      configure(auto_admin: false)

      reader = user_fixture(%{email: "restricted-reader@example.com"})
      {:ok, token, _} = Accounts.create_api_token(reader, "mcp", {:system, "test"})

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> tool("confluence_get_page", %{"page_id" => Demo.open_page()})
        |> json_response(200)

      assert body["result"]["isError"] == false

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> tool("confluence_get_page", %{"page_id" => Demo.restricted_page()})
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert [%{"text" => text}] = body["result"]["content"]
      assert text == "Page #{Demo.restricted_page()} is not mirrored."
    end

    test "an unknown tool is a JSON-RPC error", %{conn: conn} do
      body = conn |> tool("confluence_teleport", %{}) |> json_response(200)

      assert body["error"]["code"] == -32_602
      assert body["error"]["message"] =~ "confluence_teleport"
    end

    test "arguments that are not an object are refused", %{conn: conn} do
      body =
        conn
        |> rpc("tools/call", %{"name" => "confluence_search", "arguments" => "q=deploy"})
        |> json_response(200)

      assert body["error"]["code"] == -32_602
    end

    test "an unknown method is method-not-found", %{conn: conn} do
      body = conn |> rpc("resources/list") |> json_response(200)

      assert body["error"]["code"] == -32_601
    end
  end

  describe "the transport" do
    test "GET is 405 because this server offers no server-initiated stream", %{conn: conn} do
      conn = get(conn, "/api/mcp")

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST, DELETE"]
    end

    test "DELETE is 405 because there is no session to end", %{conn: conn} do
      assert delete(conn, "/api/mcp").status == 405
    end

    test "a batch is one message too many", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/mcp", JSON.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}]))

      assert json_response(conn, 400)["error"]["code"] == -32_600
    end

    test "an Origin that is not this host is refused", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.example")
        |> rpc("ping")

      assert conn.status == 403
    end

    test "an Origin of this host is fine", %{conn: conn} do
      conn = conn |> put_req_header("origin", "http://www.example.com") |> rpc("ping")

      assert json_response(conn, 200)["result"] == %{}
    end

    test "an unsupported MCP-Protocol-Version is a 400", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> rpc("ping")

      assert conn.status == 400
    end

    test "a supported MCP-Protocol-Version is accepted", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> rpc("ping")

      assert json_response(conn, 200)["result"] == %{}
    end
  end

  describe "authentication" do
    setup do
      {:ok, conn: build_conn()}
    end

    test "a demo mirror answers an anonymous caller as an administrator", %{conn: conn} do
      demo_snapshot!()
      configure(auto_admin: true)

      assert {:ok, %{}} =
               conn
               |> tool("confluence_get_page", %{"page_id" => Demo.restricted_page()})
               |> result()
    end

    test "a deployment without demo mode answers 401 and names the scheme", %{conn: conn} do
      configure(auto_admin: false)

      conn = conn |> rpc("tools/list")

      assert conn.status == 401
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(Bearer realm="confluence-mirror")
      assert challenge =~ "/.well-known/oauth-protected-resource"
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "an API token answers as its reader, and that reader's permissions apply", %{conn: conn} do
      demo_snapshot!()
      configure(auto_admin: false)

      reader = user_fixture(%{email: "mcp-reader@example.com"})
      {:ok, token, _} = Accounts.create_api_token(reader, "mcp", {:system, "test"})

      conn = put_req_header(conn, "authorization", "Bearer " <> token)

      assert {:ok, %{}} =
               conn |> tool("confluence_get_page", %{"page_id" => Demo.open_page()}) |> result()

      assert {:error, message} =
               conn
               |> tool("confluence_get_page", %{"page_id" => Demo.restricted_page()})
               |> result()

      assert message == "Page #{Demo.restricted_page()} is not mirrored."
    end

    test "a bad token is a 401, not a tool error", %{conn: conn} do
      configure(auto_admin: false)

      conn = conn |> put_req_header("authorization", "Bearer nope") |> rpc("tools/list")

      assert conn.status == 401
    end

    test "an identity the proxy established needs no token", %{conn: conn} do
      demo_snapshot!()

      configure(
        auto_admin: false,
        proxy_auth: true,
        user_policy: NewUsersCanReadPublicSpaces
      )

      conn = put_req_header(conn, "x-forwarded-email", "signed-in@example.com")

      assert {:ok, %{}} =
               conn |> tool("confluence_get_page", %{"page_id" => Demo.open_page()}) |> result()

      assert Accounts.get_user_by_email("signed-in@example.com")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp rpc(conn, method, params \\ %{}, id \\ 1) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/api/mcp",
      JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    )
  end

  defp tool(conn, name, arguments) do
    rpc(conn, "tools/call", %{"name" => name, "arguments" => arguments})
  end

  defp published_by(tools, origin) do
    for %{"name" => name, "_meta" => %{"confluence-mirror/origin" => ^origin}} <- tools, do: name
  end

  defp result(conn) do
    %{"result" => %{"content" => [%{"text" => text}], "isError" => is_error}} =
      json_response(conn, 200)

    if is_error, do: {:error, text}, else: {:ok, %{}}
  end

  defp configure(pairs) do
    Enum.each(pairs, fn {key, value} ->
      Application.put_env(:confluence_phx_mirror, key, value)
    end)
  end
end
