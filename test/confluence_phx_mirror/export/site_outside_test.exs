defmodule ConfluencePhxMirror.Export.SiteOutsideTest do
  @moduledoc """
  A body that links to a page the archive does not carry.

  Two such pages exist: one the mirror never stored, and one it holds in the
  trash. Neither is a file in the zip, so the link has to point somewhere a
  reader can actually go — the site's own address, synthesised when the mirror
  never recorded one and the recorded one when it did. A file hanging off such a
  page follows the same rule, because a path inside the archive would name a
  folder nobody wrote.

  The bundled snapshot has no upstream site at all, and that case is the third:
  the link keeps its words and loses its address rather than sending a reader to
  a website the copy has nothing to do with.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.TestConfig

  @site "https://acme.atlassian.net"
  @outside_page 999
  @recorded "https://acme.atlassian.net/wiki/spaces/ABS/pages/999/Retired"

  setup do
    space = space_fixture(%{key: "ABS", name: "Absences"})

    page =
      page_fixture(space, %{confluence_id: 1002, title: "Onboarding", body_export: body()})

    %{space: space, page: page}
  end

  test "a page the mirror never stored links to the site's address for it", %{page: page} do
    live_site()

    html = page_html(page)

    assert html =~ ~s(href="#{@site}/wiki/pages/viewpage.action?pageId=#{@outside_page}")
    assert html =~ ~s(href="#{@site}/wiki/download/attachments/#{@outside_page}/diagram.svg")
  end

  test "a page in the trash links to the address the mirror recorded", %{
    space: space,
    page: page
  } do
    live_site()

    page_fixture(space, %{confluence_id: @outside_page, external_url: @recorded})

    # The site stopped returning it, so the mirror keeps the row and stops
    # carrying it — while the page that links to it stays.
    Mirror.mark_missing_deleted(space, [page.confluence_id])

    assert {:error, :not_found} = Mirror.find_page(@outside_page)

    html = page_html(page)

    assert html =~ ~s(href="#{@recorded}")
    assert html =~ ~s(href="#{@site}/wiki/download/attachments/#{@outside_page}/diagram.svg")
    refute Map.has_key?(archive(), "spaces/ABS/pages/#{@outside_page}.html")
  end

  test "a bundled snapshot sends the reader nowhere rather than to another website", %{
    page: page
  } do
    html = page_html(page)

    # No site to ask, so the page link keeps its words and drops the address...
    assert html =~ ~s(href="#")
    # ...while the file's own address is left as the body wrote it.
    assert html =~ ~s(href="/attachments/ABS/#{@outside_page}/9001/diagram.svg")
  end

  # The mirror speaks to a site, so the export has an address to send a reader to.
  defp live_site do
    TestConfig.put(:source, HttpSource)
    TestConfig.put(HttpSource, base_url: @site)
  end

  defp body do
    """
    <p><a href="/spaces/ABS/pages/#{@outside_page}/Retired">retired</a>
    <a href="/attachments/ABS/#{@outside_page}/9001/diagram.svg">diagram</a></p>
    """
  end

  defp page_html(page) do
    Map.fetch!(archive(), "spaces/ABS/pages/#{page.confluence_id}.html")
  end

  defp archive do
    Scope.for_user(Accounts.ensure_admin!())
    |> Export.site_archive()
    |> Map.new(fn
      {name, data} -> {name, read(data)}
      {name, data, _at} -> {name, read(data)}
    end)
  end

  defp read(data) when is_function(data, 0), do: data.()
  defp read(data), do: data
end
