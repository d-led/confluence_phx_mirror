defmodule ConfluencePhxMirror.Sync.Adf.DecisionList do
  @moduledoc """
  *Decisions*: the state Confluence's HTML drops.

  A decision list is an ADF node — like a task list, not a macro — and both
  representations the API offers carry only its fallback:

      <ul class="decision-list"><li>Track decisions with a visible record.</li></ul>

  The state — decided, open, in progress — survives in the document, and the
  storage format carries that document as `<ac:adf-node>` elements. So the state
  is read from there and written onto the item the fallback drew for it, which
  gives the stylesheet something to paint it by. The item keeps its words.
  """

  @class "decision-list"
  @item ~r/<ac:adf-node\b[^>]*\btype="decision-item"[^>]*>(.*?)<\/ac:adf-node>/us
  @state ~r/<ac:adf-attribute\s+key="state"\s*>([^<]+)</u

  @doc """
  The items of every decision list in `nodes`, marked with their state.

  Both halves of the document are read in order, so the nth item meets the nth
  state the storage declares; a list the storage does not describe keeps the
  words Confluence gave it.
  """
  @spec annotate([Floki.html_node()], String.t()) :: [Floki.html_node()]
  def annotate(nodes, storage) do
    case states(storage) do
      [] -> nodes
      states -> nodes |> mark(states) |> elem(0)
    end
  end

  @doc "The states the storage declares for its decision items, in reading order."
  @spec states(String.t()) :: [String.t()]
  def states(storage) do
    @item
    |> Regex.scan(storage, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&state/1)
    |> Enum.reject(&is_nil/1)
  end

  defp state(block) do
    case Regex.run(@state, block, capture: :all_but_first) do
      [state] -> state |> String.trim() |> String.downcase()
      nil -> nil
    end
  end

  defp mark(nodes, states), do: Enum.map_reduce(nodes, states, &mark_node/2)

  defp mark_node({"ul", attrs, children}, states) do
    if decision_list?(attrs) do
      {items, rest} = Enum.map_reduce(children, states, &mark_item/2)
      {{"ul", attrs, items}, rest}
    else
      {children, rest} = mark(children, states)
      {{"ul", attrs, children}, rest}
    end
  end

  defp mark_node({tag, attrs, children}, states) do
    {children, rest} = mark(children, states)
    {{tag, attrs, children}, rest}
  end

  defp mark_node(other, states), do: {other, states}

  defp mark_item({"li", attrs, children}, states) do
    {state, rest} = take(states)
    {children, rest} = mark(children, rest)
    {{"li", put_state(attrs, state), children}, rest}
  end

  defp mark_item(node, states), do: mark_node(node, states)

  defp take([state | rest]), do: {state, rest}
  defp take([]), do: {nil, []}

  # Repairing a repaired body must change nothing, so an older marking goes.
  defp put_state(attrs, nil), do: attrs

  defp put_state(attrs, state),
    do: [{"data-decision-state", state} | Enum.reject(attrs, &state_attribute?/1)]

  defp state_attribute?({"data-decision-state", _state}), do: true
  defp state_attribute?(_attribute), do: false

  defp decision_list?(attrs) do
    Enum.any?(attrs, fn
      {"class", value} -> @class in String.split(value, ~r/\s+/u, trim: true)
      _attribute -> false
    end)
  end
end
