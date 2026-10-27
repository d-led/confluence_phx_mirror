defmodule ConfluencePhxMirrorWeb.MirrorIdentityTest do
  @moduledoc """
  Whose wiki a reader is reading.

  The header names the mirrored site (`mirror of dled.atlassian.net`), which
  falls back to "the demo snapshot" when there is no site. That fallback is why
  a screen that forgot to pass the host looked correct in the demo and wrong
  everywhere else, so these tests name a site first.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.TestConfig

  setup do
    demo_snapshot!()
    mirror_a_site("https://acme.atlassian.net")
    :ok
  end

  test "a page view says which site it mirrors", %{conn: conn} do
    html = conn |> get("/spaces/ENG/pages/1002/Architecture+Overview") |> html_response(200)

    assert html =~ "mirror of acme.atlassian.net"
    refute html =~ "mirror of the demo snapshot"
  end

  test "a space view says which site it mirrors", %{conn: conn} do
    html = conn |> get(~p"/spaces/ENG/overview") |> html_response(200)

    assert html =~ "mirror of acme.atlassian.net"
    refute html =~ "mirror of the demo snapshot"
  end

  # A configured site and a database full of demo rows: identity comes from
  # configuration, content from the mirror.
  defp mirror_a_site(url) do
    http = Application.get_env(:confluence_phx_mirror, HttpSource)

    TestConfig.put(:source, HttpSource)
    TestConfig.put(HttpSource, Keyword.put(http, :base_url, url))
  end
end
