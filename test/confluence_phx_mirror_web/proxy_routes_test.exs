defmodule ConfluencePhxMirrorWeb.ProxyRoutesTest do
  @moduledoc """
  The proxy in front of the mirror has to get out of the way of the paths the app
  authenticates itself, and keep owning the ones it does not.

  Nothing else checks this. The value lives in three files, and a missing one is
  not a crash but a `302` to GitHub on a route that has no browser behind it to
  follow it — a webhook delivery that fails, an MCP client that never learns
  where the authorization server is, an API client that gets HTML.
  """

  use ExUnit.Case, async: true

  @fly_proxies ["deploy/fly/proxy/fly.toml", "deploy/fly/proxy/fly.demo.toml"]
  @k8s_proxy "deploy/k8s/oauth2-proxy.yaml"

  # The app's own credential is the identity here: an API token, the MCP access
  # token, a delivery's signature, or a PKCE code. The proxy must not answer
  # first with a sign-in redirect.
  @app_authenticated [
    "/api/v1/pages/1002",
    "/api/mcp",
    "/api/docs",
    "/api/openapi.json",
    "/wiki/rest/api/content/1002",
    "/wiki/rest/api/content/search",
    "/webhooks/confluence",
    "/oauth/register",
    "/oauth/token",
    "/.well-known/oauth-authorization-server",
    "/.well-known/oauth-protected-resource"
  ]

  # A reader with a session cookie and a browser to follow a redirect.
  @proxied [
    "/spaces/ENG",
    "/spaces/ENG/pages/1002/Title",
    "/search",
    "/attachments/ENG/1002/7/file.png",
    "/admin/users",
    "/oauth/authorize",
    "/health"
  ]

  test "every proxy skips the paths the app authenticates" do
    for file <- @fly_proxies ++ [@k8s_proxy] do
      skip = skip_auth_routes!(file)

      for path <- @app_authenticated do
        assert skipped?(skip, path),
               "#{file}: #{path} is the app's to authenticate, but the proxy would answer first"
      end
    end
  end

  test "every proxy keeps the reader-facing paths" do
    for file <- @fly_proxies ++ [@k8s_proxy] do
      skip = skip_auth_routes!(file)

      for path <- @proxied do
        refute skipped?(skip, path),
               "#{file}: #{path} must go through the proxy's sign-in"
      end
    end
  end

  test "the three copies say the same thing" do
    [first | rest] = for file <- @fly_proxies ++ [@k8s_proxy], do: {file, skip_auth_routes!(file)}

    for {file, value} <- rest do
      assert value == elem(first, 1),
             "#{file} and #{elem(first, 0)} disagree about the skip-auth routes"
    end
  end

  # oauth2-proxy matches with POSIX ERE, which for this value is also a PCRE
  # pattern: an alternation of anchored alternatives.
  defp skipped?(pattern, path), do: Regex.match?(Regex.compile!(pattern), path)

  defp skip_auth_routes!(file) do
    text = File.read!(file)

    raw =
      captured(text, ~r/OAUTH2_PROXY_SKIP_AUTH_ROUTES *= *'([^'\n]+)'/) ||
        captured(text, ~r/OAUTH2_PROXY_SKIP_AUTH_ROUTES\s*\n\s*value: "([^"\n]+)"/) ||
        flunk("#{file} does not set OAUTH2_PROXY_SKIP_AUTH_ROUTES")

    # YAML needs `\\` for a backslash inside double quotes; TOML's literal
    # strings do not. Both reach oauth2-proxy as the same ERE.
    String.replace(raw, "\\\\", "\\")
  end

  defp captured(text, pattern) do
    case Regex.run(pattern, text) do
      [_, value] -> value
      nil -> nil
    end
  end
end
