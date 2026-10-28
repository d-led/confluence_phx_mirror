defmodule ConfluencePhxMirror.Sync.DynamicContent.StubContent do
  @moduledoc """
  A content port that answers what the test scripted, so a macro is tested as
  the small function it is — no database, no fixture pages, no sync.

      StubContent.script(children: [page])
      DynamicContent.expand(marker, %{space: space, page: page, source: StubContent})

  The script and the questions it answers live in the test process, so these
  tests can run beside the rest.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Source

  @key :dynamic_content_script
  @asked :dynamic_content_asked

  @doc "The answers this test's macros get; a keyword list, replaced on each call."
  @spec script(keyword()) :: :ok
  def script(answers) do
    Process.put(@key, answers)
    Process.put(@asked, [])
    :ok
  end

  @doc """
  Every question the macro asked, oldest first, as `{callback, argument}`.

  A macro that asks twice is tested on both — "which root did you resolve, and
  then which subtree did you read?" is one question about the macro, and keeping
  only the last answer would hide half of it.
  """
  @spec questions() :: [{atom(), term()}]
  def questions, do: @asked |> Process.get([]) |> Enum.reverse()

  @impl true
  def pages_by_label(_host, labels, _opts) do
    record({:pages_by_label, labels})
    answer(:pages_by_label, [])
  end

  @impl true
  def property_report(_host, space, columns) do
    record({:property_report, space})
    answer(:property_report, %{columns: columns, rows: []})
  end

  @impl true
  def children(_host, _page, opts) do
    record({:children, opts})
    answer(:children, [])
  end

  @impl true
  def descendants(_host, _root, opts) do
    record({:descendants, opts})
    answer(:descendants, [])
  end

  @impl true
  def page_by_title(_host, title) do
    record({:page_by_title, title})
    answer(:page_by_title, :error)
  end

  @impl true
  def search(_host, cql) do
    record({:search, cql})
    answer(:search, {:ok, []})
  end

  @impl true
  def attachments(page) do
    record({:attachments, page.confluence_id})
    answer(:attachments, [])
  end

  defp record(question), do: Process.put(@asked, [question | Process.get(@asked, [])])

  defp answer(name, default), do: @key |> Process.get([]) |> Keyword.get(name, default)
end
