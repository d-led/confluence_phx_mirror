defmodule ConfluencePhxMirror.Desktop.Web.PageTest do
  @moduledoc """
  The spaces screen's one decision: what a press will do.

  The list used to carry a submit button per row, which on a site with a
  thousand spaces is a person pressing a thousand times. It is one form now,
  and the selection is what it means — nothing ticked takes the list the filter
  shows, anything ticked takes exactly that. Both halves are markup, so they are
  tested as markup rather than through a running server.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Desktop.Web.Page

  defp spaces do
    [%{key: "ENG", name: "Engineering"}, %{key: "PROD", name: "Product"}]
  end

  test "every row is a checkbox that feeds the one button" do
    html = Page.spaces(spaces(), %{}, %{matching: 2})

    assert html =~ ~s(name="space" value="ENG" form="selection")
    assert html =~ ~s(name="space" value="PROD" form="selection")

    # One form, and it is the one the checkboxes point at.
    assert html =~ ~s(id="selection")
    assert html =~ ~s(action="/__tool/mirror")
    refute html =~ ~s(action="/__tool/mirror_all")
  end

  test "the filter is a separate form, so typing does not submit the selection" do
    html = Page.spaces(spaces(), %{}, %{matching: 2})

    assert html =~ ~s(method="get" action="/__tool/spaces")
    # A nested form is invalid HTML; the checkboxes reach the selection form by
    # the `form=` attribute instead.
    refute html =~ ~r/<form[^>]*>\s*<form/
  end

  test "the count says what the button will take, and agrees with its noun" do
    html = Page.spaces(spaces(), %{}, %{matching: 2})

    assert html =~ ~s(<span data-count>2</span>)
    assert html =~ ~s(<span data-noun>spaces</span>)

    one = Page.spaces([%{key: "ENG", name: "Engineering"}], %{}, %{matching: 1})
    assert one =~ ~s(<span data-noun>space</span>)
  end

  test "a run in flight leads to the mirror, and says how to add more" do
    run = %{state: :running, label: "ENG", done: 12, queued: 0, calls: 40}
    html = Page.spaces(spaces(), %{}, %{matching: 2, run: run})

    # The one prominent thing while a run is going is the way into the mirror —
    # not a link in the sidebar a person has to recognise.
    assert html =~ "Continue to the mirror"
    assert html =~ ~s(href="/__tool/mirror")

    # Choosing more must not vanish while a run is going, which is what it did:
    # the picker was drawn only when the tool was idle, so the button was simply
    # gone and nothing said why. It is here, under its own heading, and it says
    # what pressing it does.
    assert html =~ "Choose more spaces"
    assert html =~ "starts when the current run ends"
    assert html =~ ~s(id="selection")
    assert html =~ ~s(<button type="submit" class="secondary")
    assert html =~ ~s(data-mirror>Queue <span data-count>2</span>)
  end

  test "the way to choose more spaces is never withheld" do
    run = %{state: :running, label: "ENG", done: 12, queued: 0, calls: 40}
    queued = %{state: :queued, label: "ENG", done: 0, queued: 0, calls: 0}

    for meta <- [
          %{matching: 2},
          %{matching: 2, run: run},
          %{matching: 2, run: queued},
          %{matching: 2, loading: true}
        ] do
      html = Page.spaces(spaces(), %{}, meta)
      assert html =~ ~s(id="selection"), "no picker for #{inspect(meta)}"
    end
  end

  test "a screen whose controls are disabled says why above them" do
    html =
      Page.spaces(spaces(), %{}, %{
        matching: 2,
        loading: true,
        status: "Asking the site for its space list again…"
      })

    # Above the list, because a reason printed after a thousand rows is a reason
    # nobody reads.
    [above, _list] = String.split(html, ~s(<ul class="spaces">), parts: 2)
    assert above =~ "Asking the site for its space list again"
  end

  test "the running screen leads to the mirror too" do
    html = Page.mirror(%{state: :running, label: "ENG", done: 12, queued: 0, calls: 40})

    assert html =~ "Continue to the mirror"
    assert html =~ "Stop mirroring"
  end

  test "the screen is the whole list, so typing reaches every space" do
    html = Page.spaces(spaces(), %{}, %{matching: 2})

    # Nothing is held back for Enter to find: the server hands over every space
    # it holds and the browser filters them as you type. The count on the button
    # is then the count of what is on screen, which is the point of one search
    # rather than a client filter over the first page of a server filter.
    refute html =~ "Showing"
    refute html =~ "Narrow the filter"
  end

  test "a finished run offers the way back to the spaces" do
    html = Page.mirror(%{state: :done, label: "ENG", done: 12, queued: 0})

    assert html =~ ~s(href="/__tool/spaces")
    assert html =~ "Choose more spaces"
  end
end
