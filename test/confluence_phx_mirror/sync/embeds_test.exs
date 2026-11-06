defmodule ConfluencePhxMirror.Sync.EmbedsTest do
  @moduledoc """
  The list an operator writes down, and the policy built from it.

  A widget connector can point anywhere, and the mirror is a copy of other
  people's pages: what may be framed is a setting, not a judgement a macro makes.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Sync.Embeds
  alias ConfluencePhxMirror.TestConfig

  test "nothing is embedded until a host is named" do
    assert Embeds.embeddable?("https://www.youtube.com/watch?v=abc") == :error
    assert Embeds.frame_src() == []
  end

  test "a named host covers its subdomains, and its own address" do
    TestConfig.put(:embed_hosts, ["youtube.com"])

    assert {:ok, _address} = Embeds.embeddable?("https://youtube.com/watch?v=abc")
    assert {:ok, _address} = Embeds.embeddable?("https://www.youtube.com/watch?v=abc")
  end

  test "a host is matched, not a string that merely contains it" do
    TestConfig.put(:embed_hosts, ["youtube.com"])

    assert Embeds.embeddable?("https://youtube.com.evil.example/watch") == :error
    assert Embeds.embeddable?("https://notyoutube.com/watch") == :error
  end

  test "the list is written down however a person writes it" do
    TestConfig.put(:embed_hosts, [" YouTube.com ", "*.vimeo.com"])

    assert Embeds.hosts() == ["youtube.com", "vimeo.com"]
  end

  test "plain http is not embedded" do
    TestConfig.put(:embed_hosts, ["youtube.com"])

    assert Embeds.embeddable?("http://www.youtube.com/watch?v=abc") == :error
  end

  # How Confluence writes a widget's frame: no scheme, meaning "this page's",
  # which on this mirror is https. Read literally it had none at all, so every
  # embedded widget answered "this content cannot be shown".
  test "an address the site wrote without a scheme is https" do
    TestConfig.put(:embed_hosts, ["youtube.com"])

    assert Embeds.embeddable?("//www.youtube.com/embed/abc") ==
             {:ok, "https://www.youtube.com/embed/abc"}

    assert Embeds.embeddable?("  //www.youtube.com/embed/abc  ") ==
             {:ok, "https://www.youtube.com/embed/abc"}
  end

  test "the policy names the same hosts, so the two cannot disagree" do
    TestConfig.put(:embed_hosts, ["youtube.com"])

    assert Embeds.frame_src() == ["https://youtube.com", "https://*.youtube.com"]
  end

  test "an address a reader may follow is a web address" do
    assert {:ok, "https://example.com/a"} = Embeds.linkable?("https://example.com/a")

    assert Embeds.linkable?("javascript:alert(1)") == :error
    assert Embeds.linkable?("data:text/html,hi") == :error
    assert Embeds.linkable?("example.com/a") == :error
  end
end
