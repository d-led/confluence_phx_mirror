defmodule ConfluencePhxMirror.Sync.DynamicContent.LabelsListTest do
  @moduledoc """
  *Labels list*: a space's labels, in the four alphabetical columns Confluence's
  own macro draws.

  The mirror resolves it from its own labels rather than copying an export view,
  so the columns hold exactly what the host page's readers may open — a label
  only a narrower page carries is neither named nor drawn. What is pinned: the
  grouping is Confluence's, an empty column is not drawn, each label leads to the
  mirror's own label page, and a space the port will not scan says so.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="labels-list"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}
  @all ~w(api architecture home planning runbook service)

  setup do
    StubContent.script(labels: {:ok, @all})
  end

  test "draws the alphabetical columns Confluence draws" do
    # The site's boundaries, not an even split: 7 + 7 + 4 + 8 letters, so `r`
    # ends the third column and `runbook` sits under O-R.
    assert groups(expand()) == [
             {"A-G", ["api", "architecture"]},
             {"H-N", ["home"]},
             {"O-R", ["planning", "runbook"]},
             {"S-Z", ["service"]}
           ]
  end

  test "a column with no label is not drawn at all" do
    StubContent.script(labels: {:ok, ["api", "runbook"]})

    assert groups(expand()) == [{"A-G", ["api"]}, {"O-R", ["runbook"]}]
  end

  test "each label leads to the mirror's own label page" do
    assert hrefs(expand()) == Enum.map(@all, &"/labels/#{&1}")
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

    assert groups(html) == [
             {"A-G", ["api", "architecture"]},
             {"H-N", ["home"]},
             {"O-R", ["planning", "runbook"]},
             {"S-Z", ["service"]}
           ]
  end

  test "a space too large to scan says so instead of counting half of it" do
    StubContent.script(labels: {:error, :too_large})

    assert text(expand()) =~ "too large to list its labels in one pass"
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp groups(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("div.mirror-label-group")
    |> Enum.map(fn group ->
      title = group |> Floki.find("p.mirror-label-group-title") |> Floki.text()

      {title, group |> Floki.find("ul.mirror-label-list a") |> Enum.map(&Floki.text/1)}
    end)
  end

  defp hrefs(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("ul.mirror-label-list a")
    |> Enum.map(&Floki.attribute(&1, "href"))
    |> List.flatten()
  end
end
