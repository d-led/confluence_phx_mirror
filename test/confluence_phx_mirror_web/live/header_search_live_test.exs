defmodule ConfluencePhxMirrorWeb.HeaderSearchLiveTest do
  @moduledoc """
  The top bar's search box: a mirror of tens of thousands of pages cannot wait
  for Enter, so what matches appears under the box as the reader types.

  The list is the server's answer, narrowed to what the reader may open, and
  every line carries the address it stands for — a click on anything else is
  ignored rather than followed.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirrorWeb.HeaderSearchLive

  setup do
    demo_snapshot!()
    :ok
  end

  test "typing offers the pages whose text matches, without leaving the page" do
    {:ok, view, _html} = search()
    refute has_element?(view, "#header-search-hits")

    html = type(view, "certificate")

    assert html =~ "Certificate Rotation"
    assert has_element?(view, "[role=option]")
  end

  test "a query nothing matches says so instead of offering something else" do
    {:ok, view, _html} = search()

    html = type(view, "zzz-nothing-like-it")

    assert html =~ "No page matches that"
    refute has_element?(view, "[role=option]")
  end

  test "Enter with nothing highlighted is the search page, query and all" do
    {:ok, view, _html} = search()

    view |> element("#header-search-form") |> render_submit(%{"q" => "certificate"})

    assert_redirect(view, "/search?q=certificate")
  end

  test "a suggested page is one click away" do
    {:ok, view, _html} = search()
    html = type(view, "certificate")

    [offered | _] =
      view
      |> element("[role=option]")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-value")

    view |> element("[role=option]") |> render_click()

    assert_redirect(view, offered)
    assert html =~ "Certificate Rotation"
  end

  test "a destination the server never offered is not followed" do
    {:ok, view, _html} = search()
    type(view, "certificate")

    html = render_click(view, "open_page", %{"path" => "/admin"})

    # Still the suggestion list: the click was dropped, not turned into a trip
    # to a screen the reader asked for by hand.
    assert html =~ "Certificate Rotation"
  end

  test "Escape puts the list away and leaves the words in the box" do
    {:ok, view, _html} = search()
    type(view, "certificate")

    html = view |> render_hook("close_suggestions", %{})

    refute has_element?(view, "#header-search-hits")
    assert html =~ ~s(value="certificate")
  end

  defp search(session \\ %{}) do
    live_isolated(build_conn(), HeaderSearchLive, session: session)
  end

  defp type(view, words) do
    view |> element("#header-search-form") |> render_change(%{"q" => words})
  end
end
