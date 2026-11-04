defmodule ConfluencePhxMirror.SiteUrlTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.SiteUrl

  describe "normalize/1" do
    test "the trailing slash and the case of the host do not make a second site" do
      assert SiteUrl.normalize("https://Acme.atlassian.net/wiki/") ==
               SiteUrl.normalize("https://acme.atlassian.net/wiki")
    end

    test "a scheme's own port is not part of the site" do
      assert SiteUrl.normalize("https://acme.atlassian.net:443/wiki") ==
               "https://acme.atlassian.net/wiki"

      assert SiteUrl.normalize("http://acme.atlassian.net:80") == "http://acme.atlassian.net"
    end

    test "a port that is not the scheme's own stays, because it is another site" do
      assert SiteUrl.normalize("https://acme.atlassian.net:8443/wiki") ==
               "https://acme.atlassian.net:8443/wiki"
    end

    test "the path stays: two spaces under one host are two sites" do
      refute SiteUrl.same?("https://example.com/confluence", "https://example.com/jira")
      assert SiteUrl.same?("https://example.com/confluence", "https://example.com/confluence/")
    end

    test "a password in the address is dropped rather than kept as part of the key" do
      assert SiteUrl.normalize("https://user:hunter2@acme.atlassian.net/wiki") ==
               "https://acme.atlassian.net/wiki"
    end

    test "a query or a fragment is not the site" do
      assert SiteUrl.normalize("https://acme.atlassian.net/wiki?x=1#top") ==
               "https://acme.atlassian.net/wiki"
    end

    test "surrounding whitespace is not a different site" do
      assert SiteUrl.normalize("  https://acme.atlassian.net  ") == "https://acme.atlassian.net"
    end

    test "a bare host is the site, because https is what it can only be" do
      assert SiteUrl.normalize("acme.atlassian.net") == "https://acme.atlassian.net"
      assert SiteUrl.normalize("Acme.Atlassian.Net/wiki/") == "https://acme.atlassian.net/wiki"
      assert SiteUrl.same?("acme.atlassian.net", "https://acme.atlassian.net")
    end

    test "a bare host with a port is a host and a port, not a scheme" do
      assert SiteUrl.normalize("acme.example:8443") == "https://acme.example:8443"
      assert SiteUrl.normalize("http://acme.example:8443") == "http://acme.example:8443"
    end

    test "a scheme-relative address is the https one" do
      assert SiteUrl.normalize("//acme.atlassian.net/wiki") == "https://acme.atlassian.net/wiki"
    end

    test "an address that is not a site has no canonical form" do
      assert SiteUrl.normalize(nil) == nil
      assert SiteUrl.normalize("") == nil
      assert SiteUrl.normalize("   ") == nil
      assert SiteUrl.normalize("ftp://acme.atlassian.net") == nil
      assert SiteUrl.normalize("javascript:alert(1)") == nil
      assert SiteUrl.normalize("mailto:ops@acme.com") == nil
    end
  end

  describe "same?/2" do
    test "two absences are not one site" do
      refute SiteUrl.same?(nil, nil)
      refute SiteUrl.same?(nil, "https://acme.atlassian.net")
    end

    test "an address the tool cannot reach is the same as nothing" do
      refute SiteUrl.same?("https://acme.atlassian.net/", "ftp://acme.atlassian.net")
    end

    test "a different host is a different site, however alike the rest is" do
      refute SiteUrl.same?("https://acme.atlassian.net/wiki", "https://acme.example.net/wiki")
    end
  end
end
