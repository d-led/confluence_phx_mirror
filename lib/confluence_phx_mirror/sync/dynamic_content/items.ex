defmodule ConfluencePhxMirror.Sync.DynamicContent.Items do
  @moduledoc """
  The tasks and decisions inside a page's stored body.

  Both are *inline* content rather than macros: Confluence keeps them in the
  page's document, and the export view draws them as a list —

      <ul class="inline-task-list"><li class="checked">Whiteboard read</li></ul>
      <ul class="decision-list"><li data-decision-state="decided">Ship it</li></ul>

  — with the state on the item: a task says "ticked" by its class, a decision by
  an attribute `Sync.Adf.DecisionList` reads from the document precisely because
  the fallback drops it.

  So a report over either kind is a read of page bodies. There is no table to
  query and no index to reach for, which is why the reader is a small pure
  function: the caller decides how many bodies it will look at, and this decides
  what is inside one.

  A task's state is `"done"` or `"open"`; a decision's is the word the document
  gave it (`"decided"`, `"open"`, `"in progress"`), or `"open"` when the document
  said nothing.
  """

  @typedoc "One item: what it says, and where it stands."
  @type item :: %{text: String.t(), state: String.t()}

  # Where each kind lives in the rendered body, and how its state is spelled.
  @selectors %{tasks: "ul.inline-task-list li", decisions: "ul.decision-list li"}

  @doc """
  Every item of `kind` in `html`, in reading order.

      iex> extract(~s(<ul class="inline-task-list"><li class="checked">Read</li></ul>), :tasks)
      [%{text: "Read", state: "done"}]
  """
  @spec extract(String.t() | nil, :tasks | :decisions) :: [item()]
  def extract(html, kind) when is_binary(html) and is_map_key(@selectors, kind) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(Map.fetch!(@selectors, kind))
    |> Enum.map(&item(&1, kind))
    |> Enum.reject(&(&1.text == ""))
  end

  def extract(_html, _kind), do: []

  defp item({"li", attrs, children}, :tasks) do
    %{text: text(children), state: if(checked?(attrs), do: "done", else: "open")}
  end

  defp item({"li", attrs, children}, :decisions) do
    # A decision list whose document is not available keeps the words and says
    # nothing about the state, so the item reads as still open.
    case attribute(attrs, "data-decision-state") do
      "" -> %{text: text(children), state: "open"}
      state -> %{text: text(children), state: state}
    end
  end

  defp checked?(attrs), do: "checked" in String.split(attribute(attrs, "class"))

  # `sep: " "` keeps two blocks from running together ("Two" + "lines"), and the
  # squeeze then makes a paragraph break read as one space rather than two.
  defp text(children) do
    children
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp attribute(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_key, value} -> value
      nil -> ""
    end
  end
end
