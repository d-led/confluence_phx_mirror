defmodule ConfluencePhxMirror.Confluence.SafeURLTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Confluence.SafeURL

  @base "https://acme.atlassian.net"

  describe "validate/2" do
    test "accepts a URL on the configured host, in any case" do
      assert {:ok, uri} = SafeURL.validate("https://ACME.atlassian.net/wiki/spaces/ENG", @base)
      assert uri.host == "ACME.atlassian.net"
    end

    test "refuses a relative path in validate/2: only the resolver completes those" do
      assert {:error, :missing_host} = SafeURL.validate("/wiki/rest/api/content", @base)
    end

    test "refuses another host, scheme-relative or not" do
      assert {:error, :host_not_allowed} = SafeURL.validate("https://evil.example/x", @base)

      assert {:error, :host_not_allowed} =
               SafeURL.validate("https://acme.atlassian.net.evil/x", @base)
    end

    test "refuses credentials in the URL" do
      assert {:error, :userinfo_not_allowed} =
               SafeURL.validate("https://user:pass@acme.atlassian.net/x", @base)
    end

    test "refuses anything that is not http(s)" do
      assert {:error, :unsupported_scheme} = SafeURL.validate("ftp://acme.atlassian.net/x", @base)
      assert {:error, :missing_host} = SafeURL.validate("javascript:alert(1)", @base)
    end

    test "refuses URLs without a host and absurdly long ones" do
      assert {:error, :missing_host} =
               SafeURL.validate("mailto:someone@acme.atlassian.net", @base)

      assert {:error, :url_too_long} =
               SafeURL.validate(
                 "https://acme.atlassian.net/" <> String.duplicate("a", 2_100),
                 @base
               )
    end

    test "refuses to work without a configured base URL" do
      assert {:error, :host_not_allowed} = SafeURL.validate("https://acme.atlassian.net/x", nil)
      assert {:error, :invalid_url} = SafeURL.validate(nil, @base)
      assert {:error, :invalid_url} = SafeURL.validate(42, @base)
    end
  end

  test "resolve/2 returns the URL as a string or the reason" do
    assert {:ok, "https://acme.atlassian.net/wiki/rest/api/content"} =
             SafeURL.resolve("https://acme.atlassian.net/wiki/rest/api/content", @base)

    assert {:error, :host_not_allowed} = SafeURL.resolve("https://evil.example", @base)
  end

  test "resolve/2 completes a path relative to the base origin" do
    assert {:ok, "https://acme.atlassian.net/wiki/download/attachments/1/a.svg"} =
             SafeURL.resolve("/wiki/download/attachments/1/a.svg", @base)

    assert {:ok, "https://acme.atlassian.net/wiki"} =
             SafeURL.resolve("/wiki", "https://acme.atlassian.net/wiki")

    # Scheme-relative, so there is no scheme to allow: refused before the host.
    assert {:error, :unsupported_scheme} = SafeURL.resolve("//evil.example/x", @base)
    assert {:error, :unsupported_scheme} = SafeURL.resolve("ftp://acme.atlassian.net/x", @base)
  end
end
