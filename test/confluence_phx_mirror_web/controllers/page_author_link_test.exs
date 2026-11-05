defmodule ConfluencePhxMirrorWeb.PageAuthorLinkTest do
  @moduledoc """
  A page names its author, and the name is the way to that author.

  Confluence draws the byline as a link to the person's profile; the mirror drew
  it as a word. The profile exists here already — `/people/:account_id` answers
  for anybody the bylines name — so the only thing missing was the link.

  What a reader does with it is what is checked: follow the name and land on the
  person's page, under their name.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror.URLs

  setup do
    demo_snapshot!()
    :ok
  end

  test "the author's name on a page leads to that author's page", %{conn: conn} do
    href =
      conn
      |> get(URLs.page_path("ENG", Demo.open_page(), Demo.open_page_slug()))
      |> html_response(200)
      |> byline_href()

    assert href =~ ~r{\A/people/.+}

    # The demo's open page is written by Jane Doe, so landing on her page is what
    # following her name has to do.
    assert conn |> get(href) |> html_response(200) =~ "Jane Doe"
  end

  defp byline_href(html) do
    document = Floki.parse_document!(html)

    case Floki.find(document, "#page-byline a") do
      [link | _] ->
        link |> Floki.attribute("href") |> List.first()

      [] ->
        flunk(
          "the byline carries no link: #{Floki.find(document, "#page-byline") |> Floki.raw_html()}"
        )
    end
  end
end
