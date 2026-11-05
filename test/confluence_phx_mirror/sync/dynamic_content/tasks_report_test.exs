defmodule ConfluencePhxMirror.Sync.DynamicContent.TasksReportTest do
  @moduledoc """
  *Task report*: the tasks of a space, with the page each one lives on.

  The tasks are inline content rather than a table of their own, so the macro is
  answered from the bodies that carry them. Three claims are pinned: the report is
  the port's answer and nothing invented, each item names and links the page it
  came from, and a space the port will not scan says so rather than reporting
  part of one.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="tasks-report"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}

  setup do
    StubContent.script(
      items:
        {:ok,
         [
           %{page: page(1002, "Architecture"), text: "Whiteboard read", state: "done"},
           %{page: page(1003, "Runbook"), text: "Database linked", state: "open"}
         ]}
    )
  end

  test "lists every task with its state and the page it lives on" do
    assert rows(expand()) == [
             ["Whiteboard read", "done", "Architecture"],
             ["Database linked", "open", "Runbook"]
           ]
  end

  test "each row links the page the task came from" do
    assert hrefs(expand()) == [
             "/spaces/ENG/pages/1002/architecture",
             "/spaces/ENG/pages/1003/runbook"
           ]
  end

  test "asks the port for tasks, in the space the marker names" do
    expand()
    expand(~s(<div class="mirror-macro" data-macro="tasks-report" data-space="OPS"></div>))

    assert StubContent.questions() == [{:items, :tasks, nil}, {:items, :tasks, "OPS"}]
  end

  test "a space with no task says so" do
    StubContent.script(items: {:ok, []})

    assert text(expand()) == "No page in this space carries a task yet."
  end

  test "a space too large to scan says so instead of reporting part of it" do
    StubContent.script(items: {:error, :too_large})

    assert text(expand()) =~ "too large to report on in one pass"
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp rows(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("table.mirror-dynamic-report tbody tr")
    |> Enum.map(fn row ->
      row |> Floki.find("td") |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
    end)
  end

  defp hrefs(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("table.mirror-dynamic-report tbody a")
    |> Enum.map(&Floki.attribute(&1, "href"))
    |> List.flatten()
  end

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
