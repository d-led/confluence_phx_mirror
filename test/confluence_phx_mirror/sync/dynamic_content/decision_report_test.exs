defmodule ConfluencePhxMirror.Sync.DynamicContent.DecisionReportTest do
  @moduledoc """
  *Decision report* is the same report as the task one over a different kind of
  item, so only what differs is pinned here: the words, and the fact that the port
  is asked for decisions.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="decision-report"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}

  test "lists the decisions with their state and the page recording them" do
    StubContent.script(
      items: {:ok, [%{page: page(1002, "Decisions"), text: "Ship it", state: "decided"}]}
    )

    html = expand()

    assert html =~ "Decisions"
    assert html =~ "Ship it"
    assert html =~ "decided"
  end

  test "asks the port for decisions" do
    expand()

    assert StubContent.questions() == [{:items, :decisions, nil}]
  end

  test "a space with no decision says so" do
    StubContent.script(items: {:ok, []})

    assert text(expand()) == "No page in this space records a decision yet."
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp page(id, title) do
    %{
      id: id,
      confluence_id: id,
      title: title,
      slug: String.downcase(String.replace(title, " ", "-")),
      type: "page",
      space: @space
    }
  end
end
