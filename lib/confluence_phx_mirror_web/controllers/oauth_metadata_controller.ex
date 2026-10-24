defmodule ConfluencePhxMirrorWeb.OAuthMetadataController do
  @moduledoc """
  The two discovery documents an MCP client reads before it authenticates.

  `/.well-known/oauth-protected-resource` (RFC 9728) says which resource the
  token is for and where to get one; `/.well-known/oauth-authorization-server`
  (RFC 8414) says what the mirror can do — public clients, authorization code,
  PKCE S256. Both are static, need no credential, and are served for the bare
  path and for its `/api/mcp` suffix, which is the form a client derives from
  the resource URL.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.OAuth

  def protected_resource(conn, _params) do
    json(conn, %{
      "resource" => OAuth.resource(),
      "authorization_servers" => [authorization_server()],
      "bearer_methods_supported" => ["header"],
      "scopes_supported" => OAuth.scopes()
    })
  end

  def authorization_server(conn, _params) do
    json(conn, %{
      "issuer" => authorization_server(),
      "authorization_endpoint" => authorization_server() <> "/oauth/authorize",
      "token_endpoint" => authorization_server() <> "/oauth/token",
      "registration_endpoint" => authorization_server() <> "/oauth/register",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "code_challenge_methods_supported" => ["S256"],
      "scopes_supported" => OAuth.scopes()
    })
  end

  # The mirror is its own authorization server; the proxy in front of it only
  # logs the human in, and its host is the public one this request arrived on.
  defp authorization_server, do: ConfluencePhxMirrorWeb.Endpoint.url()
end
