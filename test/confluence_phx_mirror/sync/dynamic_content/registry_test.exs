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
             "attachments",
             "blog-posts",
             "children",
             "content-by-label",
             "content-report-table",
             "contributors",
             "detailssummary",
             "excerpt-include",
             "include",
             "pagetree",
             "recently-updated",
             "toc"
           ]
  end

  test "the friendly spellings resolve to the macro Confluence stores" do
    assert Registry.canonical("page-properties-report") == "detailssummary"
    assert Registry.fetch("page-properties-report") == Registry.fetch("detailssummary")
    assert Registry.fetch("table-of-contents") == Registry.fetch("toc")
    assert "page-properties-report" in Registry.names()
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
