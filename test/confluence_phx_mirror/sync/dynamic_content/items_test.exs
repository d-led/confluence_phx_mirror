defmodule ConfluencePhxMirror.Sync.DynamicContent.ItemsTest do
  @moduledoc """
  Reading the tasks and decisions out of a page's stored body.

  Both live inside the page, not in a table of their own: a task is an item of an
  `inline-task-list`, a decision an item of a `decision-list`. That is why a report
  over either of them is a read of bodies rather than one query, and why the reader
  is a small pure function with its own test.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent.Items

  @tasks """
  <p>before</p>
  <ul class="inline-task-list">
    <li class="checked" data-inline-task-id="1">Whiteboard read</li>
    <li data-inline-task-id="2">Database linked</li>
  </ul>
  <p>after</p>
  """

  @decisions """
  <ul class="decision-list">
    <li data-decision-state="decided">Ship it</li>
    <li data-decision-state="open">Pick a name</li>
  </ul>
  """

  test "reads every task, and whether it is ticked" do
    assert Items.extract(@tasks, :tasks) == [
             %{text: "Whiteboard read", state: "done"},
             %{text: "Database linked", state: "open"}
           ]
  end

  test "reads every decision with the state the document gave it" do
    assert Items.extract(@decisions, :decisions) == [
             %{text: "Ship it", state: "decided"},
             %{text: "Pick a name", state: "open"}
           ]
  end

  test "words inside an item are flattened to one line" do
    html = ~s(<ul class="inline-task-list"><li><p>Two</p><p>lines</p></li></ul>)

    assert Items.extract(html, :tasks) == [%{text: "Two lines", state: "open"}]
  end

  test "the tick Confluence draws beside a task is decoration, not words" do
    # Confluence puts an icon span in the item; the state is the class, so the
    # glyph would only be a stray character in the middle of a sentence.
    html = """
    <ul class="inline-task-list">
      <li class="checked"><span class="aui-icon aui-icon-small aui-iconfont-tick">✓</span> Whiteboard read</li>
      <li><span class="aui-icon aui-icon-small aui-iconfont-tick">☐</span> Database linked</li>
    </ul>
    """

    assert Items.extract(html, :tasks) == [
             %{text: "Whiteboard read", state: "done"},
             %{text: "Database linked", state: "open"}
           ]
  end

  test "a page carrying none of them yields nothing, not an error" do
    assert Items.extract("<p>nothing here</p>", :tasks) == []
    assert Items.extract("", :decisions) == []
  end
end
