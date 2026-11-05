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

  test "the count says what the button will take when nothing is ticked" do
    html = Page.spaces(spaces(), %{}, %{matching: 2})

    assert html =~ ~s(<span data-count>2</span>)
    assert html =~ ~s(<span data-noun>space</span>)
  end

  test "a run in flight owns the action, and says where to follow it" do
    run = %{state: :running, label: "ENG", done: 12, queued: 0, calls: 40}
    html = Page.spaces(spaces(), %{}, %{matching: 2, run: run})

    assert html =~ "Go to sync log"
    refute html =~ ~s(id="selection")
    refute html =~ "Mirror <span data-count>"
  end
end
