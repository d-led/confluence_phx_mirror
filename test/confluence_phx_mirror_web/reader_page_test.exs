defmodule ConfluencePhxMirrorWeb.ReaderPageTest do
  @moduledoc """
  A mirrored page is readable on its own: one `article` in the reading column
  holding the title and a byline with a machine-readable date, and nothing
  navigational inside it — so a browser's reader view can lift it out. The
  chrome around it is marked for the printer, which prints the article and
  nothing else.

  The page's body is Confluence's own HTML, which may contain `<article>`
  elements of its own; the one that matters is the page's own, a direct child
  of the reading column.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  @page "/spaces/ENG/pages/1002/Architecture+Overview"

  setup do
    demo_snapshot!()
    :ok
  end

  test "a page is one article, titled, with a dated byline", %{conn: conn} do
    article = article(conn)

    assert Enum.count(article) == 1
    assert article |> LazyHTML.query("h1") |> LazyHTML.text() =~ "Architecture Overview"

    refute Enum.empty?(LazyHTML.query(article, "time[datetime]")),
           "a reader view takes the date from a <time datetime>, not from the words"
  end

  test "nothing navigational sits inside the article", %{conn: conn} do
    article = article(conn)

    assert Enum.empty?(LazyHTML.query(article, "aside"))
    assert Enum.empty?(LazyHTML.query(article, "header nav"))
  end

  test "child pages are a navigation landmark, not prose", %{conn: conn} do
    article = article(conn)

    for nav <- LazyHTML.query(article, "nav") do
      assert LazyHTML.attribute(nav, "aria-label") == "Child pages"
    end
  end

  test "the chrome around the page is marked for the printer", %{conn: conn} do
    document = page(conn)

    assert Enum.count(LazyHTML.query(document, "header[data-print=hide]")) == 1
    assert Enum.count(LazyHTML.query(document, "footer[data-print=hide]")) == 1
    # the space tree and the rail of page facts
    assert Enum.count(LazyHTML.query(document, "aside[data-print=hide]")) == 2
    # the article is what is printed, so it is never furniture
    assert Enum.empty?(LazyHTML.query(document, "article[data-print=hide]"))
  end

  test "the footer says how many people have the mirror open", %{conn: conn} do
    widget = conn |> page() |> LazyHTML.query("footer [data-site-presence=site]")

    assert LazyHTML.text(widget) =~ "Users online:"
    assert LazyHTML.query(widget, "[data-site-presence-count]") |> LazyHTML.text() =~ ~r/^\d+$/
  end

  defp page(conn) do
    conn |> get(@page) |> html_response(200) |> LazyHTML.from_fragment()
  end

  defp article(conn), do: conn |> page() |> LazyHTML.query("#mirror-content > div > article")
end
