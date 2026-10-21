defmodule ConfluencePhxMirror.Sync.DynamicContentTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.DynamicContent

  setup do
    demo_snapshot!()
    %{space: Mirror.get_space_by_key("ENG")}
  end

  defp expand(marker, space), do: DynamicContent.expand(marker, %{space: space})

  describe "content-by-label" do
    test "lists the pages carrying the label", %{space: space} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="architecture"></div>),
          space
        )

      assert html =~ "Content by label: architecture"
      assert html =~ ~s(href="/spaces/ENG/pages/1002/architecture-overview")
      refute html =~ "Macros Gallery"
    end

    test "supports match=any across several labels", %{space: space} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="architecture,search" data-match="any"></div>),
          space
        )

      assert html =~ "Architecture Overview"
      assert html =~ "Search and CQL"
    end

    test "honours the limit", %{space: space} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="architecture,search,macros" data-match="any" data-limit="1"></div>),
          space
        )

      assert html |> String.split("<li") |> length() == 2
    end

    test "explains an empty result", %{space: space} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="nothing-here"></div>),
          space
        )

      assert html =~ "No content carries these labels yet."
    end
  end

  describe "page-properties-report" do
    test "renders a table from the properties stored during sync", %{space: space} do
      html =
        expand(
          ~s(<div class="mirror-macro" data-macro="page-properties-report" data-columns="Owner,Status"></div>),
          space
        )

      assert html =~ "Page properties report"
      assert html =~ "Architecture Overview"
      assert html =~ "Macros Gallery"
      assert html =~ "Platform"
      assert html =~ "Review"
    end
  end

  test "marks unsupported dynamic macros instead of silently dropping them", %{space: space} do
    html =
      expand(~s(<div class="mirror-macro" data-macro="content-by-user"></div>), space)

    assert html =~ "not supported by the mirror"
  end

  test "leaves ordinary markup untouched", %{space: space} do
    html = expand("<p>Plain <strong>content</strong>.</p>", space)

    assert html == "<p>Plain <strong>content</strong>.</p>"
  end
end
