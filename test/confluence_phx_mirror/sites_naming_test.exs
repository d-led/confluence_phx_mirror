defmodule ConfluencePhxMirror.SitesNamingTest do
  @moduledoc """
  What the mirror calls itself. A reader should be able to tell from the title
  bar whose wiki they are looking at, so a live site lends its name, and the
  bundled snapshot, which stands for no site, keeps the neutral one.
  """

  # The configured site is global state, so these tests take turns.
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Sites

  test "the bundled snapshot has no site, so it keeps the product name" do
    assert Sites.name() == "Confluence Mirror"
    assert Sites.host() == nil
    assert Sites.current().kind == :demo
  end

  test "a live site is named after the first label of its host" do
    configure_site("https://dled.atlassian.net/wiki")

    assert Sites.name() == "dled"
    assert Sites.host() == "dled.atlassian.net"
    assert Sites.current().kind == :live
  end

  test "a configured url with no host cannot name a site" do
    configure_site("not a url")

    assert Sites.host() == nil
    assert Sites.name() == "Confluence Mirror"
  end

  test "a live site with no url at all cannot name a site" do
    configure_site(nil)

    assert Sites.host() == nil
    assert Sites.name() == "Confluence Mirror"
  end

  defp configure_site(url) do
    previous_source = Application.get_env(:confluence_phx_mirror, :source)
    previous_http = Application.get_env(:confluence_phx_mirror, HttpSource)

    Application.put_env(:confluence_phx_mirror, :source, HttpSource)
    Application.put_env(:confluence_phx_mirror, HttpSource, base_url: url)

    on_exit(fn ->
      Application.put_env(:confluence_phx_mirror, :source, previous_source)
      Application.put_env(:confluence_phx_mirror, HttpSource, previous_http)
    end)
  end
end
