defmodule ConfluencePhxMirror.Sync.DynamicContentTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.DynamicContent

  setup do
    demo_snapshot!()

    {:ok, host} = Mirror.find_page_by_path("ENG", Demo.open_page_number())
    {:ok, restricted_host} = Mirror.find_page_by_path("ENG", Demo.restricted_page_number())

    %{host: host, restricted_host: restricted_host}
  end

  defp expand(marker, host), do: DynamicContent.expand(marker, %{space: host.space, page: host})

  describe "content-by-label" do
    test "lists the pages carrying the label", %{host: host} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="architecture"></div>),
          host
        )

      assert html =~ "Content by label: architecture"
      assert html =~ ~s(href="/spaces/ENG/pages/1002/Architecture+Overview")
      refute html =~ Demo.restricted_page_title()
    end

    test "supports match=any across several labels", %{host: host} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="architecture,search" data-match="any"></div>),
          host
        )

      assert html =~ "Architecture Overview"
      assert html =~ "Search and CQL"
    end

    test "honours the limit", %{host: host} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="architecture,search,macros" data-match="any" data-limit="1"></div>),
          host
        )

      assert html |> String.split("<li") |> length() == 2
    end

    test "explains an empty result", %{host: host} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="nothing-here"></div>),
          host
        )

      assert html =~ "No content carries these labels yet."
    end

    test "an open page does not name a page its readers may not open", %{host: host} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="macros"></div>),
          host
        )

      refute html =~ Demo.restricted_page_title()
      assert html =~ "No content carries these labels yet."
    end

    test "a page restricted to the same group may name it", %{restricted_host: host} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="macros"></div>),
          host
        )

      assert html =~ Demo.restricted_page_title()
    end
  end

  describe "page-properties-report" do
    test "renders a table from the properties stored during sync", %{restricted_host: host} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="page-properties-report" data-columns="Owner,Status"></div>),
          host
        )

      assert html =~ "Page properties report"
      assert html =~ "Architecture Overview"
      assert html =~ "Macros Gallery"
      assert html =~ "Platform"
      assert html =~ "Review"
    end

    test "leaves out rows an open page's readers may not open", %{host: host} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="page-properties-report" data-columns="Owner,Status"></div>),
          host
        )

      assert html =~ "Architecture Overview"
      refute html =~ Demo.restricted_page_title()
    end
  end

  test "marks unsupported dynamic macros instead of silently dropping them", %{host: host} do
    html =
      expand(~s(<div class="mirror-macro" data-macro="content-by-user"></div>), host)

    assert html =~ "not supported by the mirror"
  end

  test "leaves ordinary markup untouched", %{host: host} do
    html = expand("<p>Plain <strong>content</strong>.</p>", host)

    assert html == "<p>Plain <strong>content</strong>.</p>"
  end

  describe "toc" do
    test "links the headings of the body it is expanding", %{host: host} do
      html =
        expand(
          ~s(<h2 id="first">First</h2><div class="mirror-macro" data-macro="toc"></div>),
          host
        )

      assert html =~ ~s(href="#first")
      assert html =~ "First"
    end
  end

  describe "children" do
    test "lists the pages below, and leaves out one its readers may not open", %{host: host} do
      {:ok, parent} = Mirror.find_page(Demo.open_page_parent_number())

      html =
        DynamicContent.expand(~s(<div class="mirror-macro" data-macro="children"></div>), %{
          space: host.space,
          page: parent
        })

      assert html =~ Demo.open_page_title()
      refute html =~ Demo.restricted_page_title(), "a child list may not hand a restriction away"
    end
  end
end
