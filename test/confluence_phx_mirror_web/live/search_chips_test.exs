defmodule ConfluencePhxMirrorWeb.Live.SearchChipsTest do
  @moduledoc """
  Every filter a reader applies is echoed back as a chip in words, so the
  current search can be read without decoding the URL.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ConfluencePhxMirror.Fixtures

  setup do
    demo_snapshot!()
    :ok
  end

  test "each filter becomes a chip that names what it does", %{conn: conn} do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/search?q=pipeline&phrase=sync+architecture&any=gallery&none=draft&space=ENG&spaces=ENG,PROD&creator=jane&sort=newest&types=blogpost&updated=30d"
      )

    for label <- [
          "pipeline",
          "Phrase: sync architecture",
          "Any of: gallery",
          "None of: draft",
          "Space: ENG",
          "Spaces: ENG, PROD",
          "By: jane",
          "Sort: newest first",
          "Type: blog posts",
          "Past 30 days"
        ] do
      assert has_element?(view, "a", label)
    end
  end

  test "the date window and time ranges name themselves", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, ~p"/search?q=pipeline&from=2026-01-01&to=2026-06-01&updated=7d")

    assert has_element?(view, "a", "Modified after 2026-01-01")
    assert has_element?(view, "a", "Modified before 2026-06-01")
    assert has_element?(view, "a", "Past 7 days")
  end
end
