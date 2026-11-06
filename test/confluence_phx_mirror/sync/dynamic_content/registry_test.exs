defmodule ConfluencePhxMirror.Sync.DynamicContent.RegistryTest do
  @moduledoc """
  What the mirror can draw, and the promise each entry makes.

  A macro name in the registry is a claim that writing that marker on a page
  produces HTML rather than a notice, so the claim is checked here once instead
  of once per macro.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.Registry
  alias ConfluencePhxMirror.Sync.DynamicContent.Renderer

  test "every registered name has a renderer that the expander can call" do
    assert Registry.macros() != []

    for name <- Registry.macros() do
      assert {:ok, renderer} = Registry.fetch(name)
      assert Renderer.implements?(renderer), "#{name} is registered without a render/2"
    end
  end

  test "the names the mirror draws are Confluence's own ac:name keys" do
    assert Registry.macros() == [
             "anchor",
             "attachments",
             "blog-posts",
             "children",
             "content-by-label",
             "content-report-table",
             "contributors",
             "decision-report",
             "detailssummary",
             "excerpt-include",
             "include",
             "labels-list",
             "livesearch",
             "native-embed:database",
             "native-embed:whiteboard",
             "pagetree",
             "profile-picture",
             "recently-updated",
             "roadmap",
             "tasks-report",
             "toc",
             "user-profile",
             "widget"
           ]
  end

  test "the friendly spellings resolve to the macro Confluence stores" do
    assert Registry.canonical("page-properties-report") == "detailssummary"
    assert Registry.fetch("page-properties-report") == Registry.fetch("detailssummary")
    assert Registry.fetch("table-of-contents") == Registry.fetch("toc")
    assert Registry.fetch("widget-connector") == Registry.fetch("widget")
    assert "page-properties-report" in Registry.names()
  end

  # Both spellings sit on one page in the wild: the editor writes
  # `contentbylabel`, the API writes `content-by-label`.
  test "a macro the editor spells differently is the same macro" do
    assert Registry.fetch("contentbylabel") == Registry.fetch("content-by-label")
    assert Registry.canonical("contentbylabel") == "content-by-label"
  end

  test "a macro the mirror does not know is not a registered name" do
    assert Registry.fetch("content-by-user") == :error
  end

  test "a registered renderer is reachable through the expander" do
    page = %{id: 1, confluence_id: 1, slug: "page-1", title: "Page", space: %{key: "ENG"}}

    html =
      DynamicContent.expand(~s(<div class="mirror-macro" data-macro="toc"></div>), %{
        space: page.space,
        page: page
      })

    assert Floki.find(Floki.parse_fragment!(html), "p.mirror-dynamic-empty") != []
  end
end
