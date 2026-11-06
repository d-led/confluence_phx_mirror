defmodule ConfluencePhxMirror.Sync.DynamicContent.ContentByLabelTest do
  @moduledoc """
  *Content by Label* lists the pages carrying a label, and the question is half
  the macro: the labels, whether any or all of them must match, how many pages,
  and the space when the marker names one.

  The listing itself is the port's answer — what a reader may open is decided
  there, once, for every macro — so these tests pin what the macro asks and what
  it draws of the answer.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="runbook,incident"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Runbooks", space: @space}

  setup do
    StubContent.script(pages_by_label: [page(2, "Deploys"), page(3, "On call")])
  end

  test "lists the pages the port answers, under a heading that names the labels" do
    html = expand()

    assert titles(html) == ["Deploys", "On call"]
    assert Floki.text(Floki.parse_fragment!(html)) =~ "Content by label: runbook, incident"
  end

  test "each row is the page's own route in the mirror" do
    assert hrefs(expand()) == ["/spaces/ENG/pages/2/Deploys", "/spaces/ENG/pages/3/On+call"]
  end

  test "asks for every label, ten pages, in whatever space the page lives" do
    expand()

    assert asked() == {["runbook", "incident"], [match: :all, limit: 10, space: nil]}
  end

  test "asks for any of them when the marker says so" do
    expand(
      ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="runbook,incident" data-match="any"></div>)
    )

    assert {_labels, opts} = asked()
    assert opts[:match] == :any
  end

  test "asks for as many pages as the marker allows" do
    expand(
      ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="runbook" data-limit="5"></div>)
    )

    assert {_labels, opts} = asked()
    assert opts[:limit] == 5
  end

  test "asks in the space the marker names, not the page's own" do
    expand(
      ~s(<div class="mirror-macro" data-macro="content-by-label" data-labels="runbook" data-space="OPS"></div>)
    )

    assert {_labels, opts} = asked()
    assert opts[:space] == "OPS"
  end

  test "a macro that names no label says why there is nothing to list" do
    assert text(expand(~s(<div class="mirror-macro" data-macro="content-by-label"></div>))) ==
             "The macro names no label, so there is nothing to list."

    # An empty query is not a question worth asking.
    assert StubContent.questions() == []
  end

  test "nothing carrying the label yet is said plainly" do
    StubContent.script(pages_by_label: [])

    assert text(expand()) == "No content carries these labels yet."
  end

  defp asked do
    assert [{:pages_by_label, labels, opts}] = StubContent.questions()
    {labels, opts}
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp titles(html), do: html |> links() |> Enum.map(&Floki.text/1)

  defp hrefs(html),
    do: html |> links() |> Enum.map(&(&1 |> Floki.attribute("href") |> List.first()))

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp links(html),
    do: html |> Floki.parse_fragment!() |> Floki.find("ul.mirror-dynamic-list a")

  defp page(id, title) do
    %{
      id: id,
      confluence_id: id,
      title: title,
      slug: Page.slugify(title),
      type: "page",
      space: @space,
      external_updated_at: ~U[2026-10-01 09:00:00Z]
    }
  end
end
