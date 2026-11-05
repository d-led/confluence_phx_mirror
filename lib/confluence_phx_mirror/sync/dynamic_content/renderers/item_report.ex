defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.ItemReport do
  @moduledoc """
  The two reports over inline content — *Task report* and *Decision report*.

  Tasks and decisions are not macros: they are items inside pages, and Confluence
  leaves these two macros unexpanded for a reader without a browser. So the answer
  is a read of the pages that carry such items, which is why both reports share
  this module and differ only in the words they use.

  What it will not do: report part of a space. The port reads a capped number of
  bodies and answers `:too_large` past it, because "twelve tasks" that quietly
  stopped halfway is worse than a sentence saying the space is too big to read in
  one pass. Every page named in the report is one the host's readers may open —
  the port narrows before anything is extracted.
  """

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

  @words %{
    tasks: %{title: "Tasks", empty: "No page in this space carries a task yet."},
    decisions: %{title: "Decisions", empty: "No page in this space records a decision yet."}
  }

  @doc """
  The report for `kind`, as the page's own space sees it.

  `attrs` may name another space with `data-space`, the way Confluence's macro
  allows; a key the mirror does not hold falls back to the host's own space.
  """
  @spec draw(:tasks | :decisions, map(), Context.t()) :: [Floki.html_node()]
  def draw(kind, attrs, %Context{} = context) do
    %{title: title, empty: empty} = Map.fetch!(@words, kind)

    case context.source.items(context.page, Map.get(attrs, "space"), kind, []) do
      {:ok, []} ->
        [Nodes.empty(empty)]

      {:ok, items} ->
        [Nodes.heading(title), Nodes.item_report(items, context.space.key)]

      {:error, :too_large} ->
        [Nodes.notice("This space is too large to report on in one pass.")]
    end
  end
end
