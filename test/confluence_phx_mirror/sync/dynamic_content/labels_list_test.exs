defmodule ConfluencePhxMirror.Sync.DynamicContent.LabelsListTest do
  @moduledoc """
  *Labels list* is the space's labels, most used first.

  Confluence never renders it for a reader without a browser session, so the
  marker is all a sync can read — the same five macros the gallery page shows as
  placeholders. Three claims are pinned: the list is the port's answer and nothing
  invented, each label leads to the mirror's own label page, and a space the port
  will not scan says so rather than counting half of it.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="labels-list"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}

  setup do
    StubContent.script(
      labels: {:ok, [%{name: "runbook", pages: 12}, %{name: "incident", pages: 1}]}
    )
  end

  test "lists the labels the port counted, with the pages each one is on" do
    html = expand()

    assert text(html) =~ "Labels"
    assert labels(html) == ["runbook · 12 pages", "incident · 1 page"]
  end

  test "each label leads to the mirror's own label page" do
    html = expand()

    assert hrefs(html) == ["/labels/runbook", "/labels/incident"]
  end

  test "asks about the space the marker names" do
    expand()

    expand(~s(<div class="mirror-macro" data-macro="labels-list" data-space="OPS"></div>))

    assert StubContent.questions() == [{:labels, nil}, {:labels, "OPS"}]
  end

  test "a space where no page carries a label says that" do
    StubContent.script(labels: {:ok, []})

    assert text(expand()) == "No page in this space carries a label yet."
  end

  test "the editor's own spelling of the macro draws the same list" do
    # Confluence's editor writes `listlabels` into storage; the page that was
    # seeded through the API carried `labels-list`. Both are the same macro, and
    # a page may hold either, so the mirror has to answer to both.
    html = expand(~s(<div class="mirror-macro" data-macro="listlabels"></div>))

    assert labels(html) == ["runbook · 12 pages", "incident · 1 page"]
  end

  test "a space too large to scan says so instead of counting half of it" do
    StubContent.script(labels: {:error, :too_large})

    assert text(expand()) =~ "too large to list its labels in one pass"
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp labels(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("ul.mirror-label-list li")
    |> Enum.map(&(&1 |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp hrefs(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("ul.mirror-label-list a")
    |> Enum.map(&Floki.attribute(&1, "href"))
    |> List.flatten()
  end
end
