defmodule ConfluencePhxMirror.SitesTest do
  @moduledoc """
  A mirror holds one site. These tests pin the rules that keep two sites from
  ever sharing a database.
  """
  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Sites
  alias ConfluencePhxMirror.TestConfig

  describe "site keys" do
    test "the demo snapshot is its own site" do
      assert Sites.key_for(nil) == "demo"
      assert Sites.key_for("") == "demo"
    end

    test "a real site is named after its host" do
      assert Sites.key_for("https://dled.atlassian.net/wiki") == "dled_atlassian_net"
      assert Sites.key_for("https://dled.atlassian.net") == "dled_atlassian_net"
    end

    test "hosts that differ only by punctuation still get different databases" do
      refute Sites.key_for("https://a-b.example.com") == Sites.key_for("https://ab.example.com")
    end

    test "each site gets its own database name" do
      assert Sites.database("confluence_phx_mirror_dev", "demo") ==
               "confluence_phx_mirror_dev_demo"
    end
  end

  describe "site identity of a database" do
    test "the first boot records the site" do
      assert Sites.verify!() == :ok
      assert Repo.get!(ConfluencePhxMirror.Sites.Site, 1).key == "demo"
    end

    test "a database recorded as demo refuses a real site" do
      assert Sites.verify!() == :ok
      with_site("https://dled.atlassian.net/wiki")

      assert_raise RuntimeError, ~r/Refusing to mix two Confluence sites/, fn ->
        Sites.verify!()
      end
    end

    test "a database recorded as demo accepts the demo again" do
      assert Sites.verify!() == :ok
      assert Sites.verify!() == :ok
    end
  end

  # Pretends the deployment is configured for a real Confluence site.
  defp with_site(url) do
    TestConfig.put(:source, HttpSource)
    TestConfig.put(HttpSource, base_url: url)
  end
end
