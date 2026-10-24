defmodule ConfluencePhxMirrorWeb.OAuthTest do
  @moduledoc """
  The MCP authorization server end to end: discovery, registration, consent and
  the code exchange, then the token used against the MCP endpoint and the JSON
  API.

  The point of the flow is that nobody pastes a token, so the tests walk it the
  way a client does — registering itself, sending the reader's browser to the
  consent page, and trading the returned code for a token — and then check that
  the token is worth exactly what the reader who approved it was worth.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.OAuth

  @redirect_uri "http://127.0.0.1:33418/callback"
  @verifier "a-verifier-long-enough-for-rfc-7636-0123456789-abcdef"

  setup do
    previous = Application.fetch_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:confluence_phx_mirror, :auto_admin, value)
        :error -> Application.delete_env(:confluence_phx_mirror, :auto_admin)
      end
    end)

    :ok
  end

  describe "discovery" do
    test "the protected-resource document names the MCP endpoint and the server", %{conn: conn} do
      body = conn |> get("/.well-known/oauth-protected-resource") |> json_response(200)

      assert body["resource"] == ConfluencePhxMirrorWeb.Endpoint.url() <> "/api/mcp"
      assert body["authorization_servers"] == [ConfluencePhxMirrorWeb.Endpoint.url()]
      assert body["bearer_methods_supported"] == ["header"]
    end

    test "the same document is served under the resource's own path", %{conn: conn} do
      body = conn |> get("/.well-known/oauth-protected-resource/api/mcp") |> json_response(200)

      assert body["resource"] == ConfluencePhxMirrorWeb.Endpoint.url() <> "/api/mcp"
    end

    test "the authorization-server document says code + PKCE and nothing else", %{conn: conn} do
      body = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)

      assert body["authorization_endpoint"] ==
               ConfluencePhxMirrorWeb.Endpoint.url() <> "/oauth/authorize"

      assert body["token_endpoint"] == ConfluencePhxMirrorWeb.Endpoint.url() <> "/oauth/token"

      assert body["registration_endpoint"] ==
               ConfluencePhxMirrorWeb.Endpoint.url() <> "/oauth/register"

      assert body["code_challenge_methods_supported"] == ["S256"]
      assert body["token_endpoint_auth_methods_supported"] == ["none"]
    end
  end

  describe "registration" do
    test "a public client registers itself and gets a client id", %{conn: conn} do
      body = register(conn)

      assert body["redirect_uris"] == [@redirect_uri]
      assert body["token_endpoint_auth_method"] == "none"
      assert is_binary(body["client_id"])
      assert {:ok, client} = OAuth.client(body["client_id"])
      assert client["redirect_uris"] == [@redirect_uri]
    end

    test "a redirect URI that is not absolute http(s) is refused", %{conn: conn} do
      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/oauth/register", JSON.encode!(%{"redirect_uris" => ["javascript:alert(1)"]}))
        |> json_response(400)

      assert body["error"] == "invalid_redirect_uri"
    end

    test "a confidential client is refused, because there is no secret store", %{conn: conn} do
      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/oauth/register",
          JSON.encode!(%{
            "redirect_uris" => [@redirect_uri],
            "token_endpoint_auth_method" => "client_secret_basic"
          })
        )
        |> json_response(400)

      assert body["error"] == "invalid_client_metadata"
    end
  end

  describe "authorization" do
    test "a browser that has not signed in is sent to the mirror's sign-in", %{conn: conn} do
      client = register(conn)

      conn = get(conn, authorize_path(client["client_id"]))

      assert redirected_to(conn) == "/session"
    end

    test "the consent page names the client, the mirror and the reader", %{conn: conn} do
      reader = user_fixture(%{email: "consent@example.com"})
      client = register(conn)

      html =
        conn
        |> signed_in(reader)
        |> get(authorize_path(client["client_id"]))
        |> html_response(200)

      assert html =~ "An MCP client"
      assert html =~ "consent@example.com"
      assert html =~ "_csrf_token"
    end

    test "approving redirects back with a code", %{conn: conn} do
      reader = user_fixture(%{email: "approve@example.com"})
      client = register(conn)

      conn =
        conn
        |> signed_in(reader)
        |> post(
          "/oauth/authorize",
          authorize_params(client["client_id"]) |> Map.put("decision", "approve")
        )

      assert %URI{host: "127.0.0.1", path: "/callback"} = URI.parse(redirected_to(conn))

      query = URI.parse(redirected_to(conn)).query |> URI.query_decoder() |> Map.new()

      assert query["state"] == "xyz"
      assert is_binary(query["code"])
    end

    test "denying redirects back with access_denied instead of a code", %{conn: conn} do
      reader = user_fixture(%{email: "deny@example.com"})
      client = register(conn)

      url =
        conn
        |> signed_in(reader)
        |> post(
          "/oauth/authorize",
          authorize_params(client["client_id"]) |> Map.put("decision", "deny")
        )
        |> redirected_to()

      assert URI.parse(url).query =~ "error=access_denied"
      refute URI.parse(url).query =~ "code="
    end

    test "an unregistered redirect URI is refused before anything is sent back", %{conn: conn} do
      reader = user_fixture(%{email: "bad-redirect@example.com"})
      client = register(conn)

      params =
        client["client_id"]
        |> authorize_params()
        |> Map.put("redirect_uri", "https://evil.example/callback")

      conn = conn |> signed_in(reader) |> get("/oauth/authorize?#{URI.encode_query(params)}")

      assert conn.status == 400
      assert response(conn, 400) =~ "redirect_uri"
    end
  end

  describe "the token, and what it is worth" do
    test "an approved reader gets a token that reads the mirror as they do", %{conn: conn} do
      demo_snapshot!()
      reader = user_fixture(%{email: "token-reader@example.com"})
      token = grant(conn, reader)

      conn = put_req_header(conn, "authorization", "Bearer " <> token)

      assert {:ok, _} = call_tool(conn, "confluence_get_page", %{"page_id" => Demo.open_page()})

      restricted = Demo.restricted_page()

      assert {:error, message} =
               call_tool(conn, "confluence_get_page", %{"page_id" => restricted})

      assert message == "Page #{restricted} is not mirrored."

      page = conn |> get("/api/v1/pages/#{Demo.open_page()}") |> json_response(200)
      assert page["title"] == Demo.open_page_title()
    end

    test "a wrong verifier buys nothing", %{conn: conn} do
      reader = user_fixture(%{email: "wrong-verifier@example.com"})
      client = register(conn)
      code = code_for(conn, reader, client)

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/oauth/token",
          JSON.encode!(%{
            "grant_type" => "authorization_code",
            "code" => code,
            "redirect_uri" => @redirect_uri,
            "client_id" => client["client_id"],
            "code_verifier" => String.duplicate("x", 64)
          })
        )
        |> json_response(400)

      assert body["error"] == "invalid_grant"
    end

    test "a code presented by another client is refused", %{conn: conn} do
      reader = user_fixture(%{email: "other-client@example.com"})
      mine = register(conn)
      other = register(conn, "https://other.example/callback")
      code = code_for(conn, reader, mine)

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/oauth/token",
          JSON.encode!(%{
            "grant_type" => "authorization_code",
            "code" => code,
            "redirect_uri" => @redirect_uri,
            "client_id" => other["client_id"],
            "code_verifier" => @verifier
          })
        )
        |> json_response(400)

      assert body["error"] == "invalid_grant"
    end
  end

  describe "the challenge that starts the flow" do
    test "an unauthenticated MCP call points at the resource metadata", %{conn: conn} do
      conn =
        conn |> put_req_header("content-type", "application/json") |> post("/api/mcp", ping())

      assert conn.status == 401

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer realm="confluence-mirror", resource_metadata="#{ConfluencePhxMirrorWeb.Endpoint.url()}/.well-known/oauth-protected-resource")
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp register(conn, redirect_uri \\ @redirect_uri) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/oauth/register",
      JSON.encode!(%{"client_name" => "An MCP client", "redirect_uris" => [redirect_uri]})
    )
    |> json_response(201)
  end

  defp authorize_path(client_id) do
    "/oauth/authorize?" <> URI.encode_query(authorize_params(client_id))
  end

  defp authorize_params(client_id) do
    %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => @redirect_uri,
      "state" => "xyz",
      "code_challenge" => OAuth.challenge(@verifier),
      "code_challenge_method" => "S256"
    }
  end

  defp code_for(conn, reader, client) do
    url =
      conn
      |> signed_in(reader)
      |> post(
        "/oauth/authorize",
        authorize_params(client["client_id"]) |> Map.put("decision", "approve")
      )
      |> redirected_to()

    {_, code} = URI.query_decoder(URI.parse(url).query) |> Enum.find(&(elem(&1, 0) == "code"))
    code
  end

  defp grant(conn, reader) do
    client = register(conn)
    code = code_for(conn, reader, client)

    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/oauth/token",
        JSON.encode!(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => @redirect_uri,
          "client_id" => client["client_id"],
          "code_verifier" => @verifier
        })
      )
      |> json_response(200)

    body["access_token"]
  end

  defp call_tool(conn, name, arguments) do
    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/mcp",
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => name, "arguments" => arguments}
        })
      )
      |> json_response(200)

    case body["result"] do
      %{"isError" => true, "content" => [%{"text" => text}]} -> {:error, text}
      %{"content" => [%{"text" => text}]} -> {:ok, text}
      other -> other
    end
  end

  defp ping do
    JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
  end

  defp signed_in(conn, user), do: init_test_session(conn, user_id: user.id)
end
