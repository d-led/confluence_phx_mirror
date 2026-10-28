defmodule ConfluencePhxMirror.Sync.DynamicContent.StubContent do
  @moduledoc """
  A content port that answers what the test scripted, so a macro is tested as
  the small function it is — no database, no fixture pages, no sync.

      StubContent.script(children: [page])
      DynamicContent.expand(marker, %{space: space, page: page, source: StubContent})

  The script lives in the test process, so these tests can run beside the rest.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Source

  @key :dynamic_content_script
  @asked :dynamic_content_asked

  @doc "The answers this test's macros get; a keyword list, replaced on each call."
  @spec script(keyword()) :: :ok
  def script(answers) do
    Process.put(@key, answers)
    :ok
  end

  @doc "The options the last `children/3` question carried."
  @spec asked() :: keyword()
  def asked, do: Process.get(@asked, [])

  @impl true
  def pages_by_label(_host, _labels, _opts), do: answer(:pages_by_label, [])

  @impl true
  def property_report(_host, _space, columns),
    do: answer(:property_report, %{columns: columns, rows: []})

  @impl true
  def children(_host, _page, opts) do
    Process.put(@asked, opts)
    answer(:children, [])
  end

  defp answer(name, default), do: @key |> Process.get([]) |> Keyword.get(name, default)
end
