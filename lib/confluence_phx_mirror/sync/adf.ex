defmodule ConfluencePhxMirror.Sync.Adf do
  @moduledoc """
  What Confluence's HTML loses about the document behind it, put back.

  `export_view` is HTML, and a few nodes of the editor's document do not survive
  that trip whole: a decision list arrives as its fallback,
  `<ul class="decision-list">` — the words, without the state that says whether
  the decision was taken. The storage format carries the same document as
  `<ac:adf-node>` elements, so what the HTML dropped is still here at render
  time, and this pass hands it to the module that knows the node.

  One module per ADF node type, the way the macro layer has one per macro name.
  A node kind with no module keeps exactly the HTML Confluence drew for it: the
  fallback is what the site itself ships, so silence is the safe answer.
  """

  alias ConfluencePhxMirror.Sync.Adf.{DecisionList, Panel}

  @nodes [DecisionList, Panel]

  @doc """
  Every registered node in `nodes`, repaired from `context[:storage]`.

  A body from a source that carries no storage cannot be repaired — the export
  view is all there is — so it comes back as it went in.
  """
  @spec repair([Floki.html_node()], map()) :: [Floki.html_node()]
  def repair(nodes, %{storage: storage}) when is_binary(storage),
    do: Enum.reduce(@nodes, nodes, fn node, acc -> node.annotate(acc, storage) end)

  def repair(nodes, _context), do: nodes
end
