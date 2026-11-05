defmodule ConfluencePhxMirror.Sync.Adf.Panel do
  @moduledoc """
  *Panels*: the kind Confluence's HTML drops.

  A panel drawn by the modern editor is an ADF node that names its kind:

      <ac:adf-node type="panel">
        <ac:adf-attribute key="panel-type">note</ac:adf-attribute>
        …
      </ac:adf-node>

  Confluence draws that kind's tone and icon. The export view carries none of
  it — only a plain `.panel` with whatever colours the author picked — so the
  kinds are read from the storage and written onto the panels it drew for them,
  in reading order. The panel then carries the classes an information macro
  carries, which is the point: one vocabulary draws both, and the pastel written
  for a light page is not part of it.
  """

  @panel ~r/<ac:adf-node\b[^>]*\btype="panel"[^>]*>(.*?)<\/ac:adf-node>/us
  @kind ~r/<ac:adf-attribute\s+key="panel-type"\s*>([^<]+)</u

  # The mirror's information macros have no `success`: a green tick is a tip.
  @kinds %{
    "info" => "info",
    "note" => "note",
    "tip" => "tip",
    "success" => "tip",
    "warning" => "warning",
    "error" => "error"
  }

  @doc """
  The typed panels in `nodes`, marked with the kind the storage declares.

  Both halves of the document are read in order, so the nth panel meets the nth
  declaration; a panel the storage does not describe keeps the words and the
  colours Confluence gave it.
  """
  @spec annotate([Floki.html_node()], String.t()) :: [Floki.html_node()]
  def annotate(nodes, storage) do
    case kinds(storage) do
      [] -> nodes
      kinds -> nodes |> mark(kinds) |> elem(0)
    end
  end

  @doc """
  The kind of every panel the storage declares, in reading order.

  A panel with no kind answers `nil` rather than dropping out: the nth panel in
  the body meets the nth declaration, and an absent kind is not the next one.
  """
  @spec kinds(String.t()) :: [String.t() | nil]
  def kinds(storage) do
    @panel
    |> Regex.scan(storage, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&kind/1)
  end

  defp kind(block) do
    case Regex.run(@kind, block, capture: :all_but_first) do
      [kind] -> kind |> String.trim() |> String.downcase() |> then(&Map.get(@kinds, &1))
      nil -> nil
    end
  end

  defp mark(nodes, kinds), do: Enum.map_reduce(nodes, kinds, &mark_node/2)

  defp mark_node({"div", attrs, children}, [kind | rest] = kinds) do
    if panel?(attrs) do
      {children, rest} = mark(children, rest)
      {{"div", typed(attrs, kind), badge(children, kind)}, rest}
    else
      {children, kinds} = mark(children, kinds)
      {{"div", attrs, children}, kinds}
    end
  end

  defp mark_node({tag, attrs, children}, kinds) do
    {children, kinds} = mark(children, kinds)
    {{tag, attrs, children}, kinds}
  end

  defp mark_node(other, kinds), do: {other, kinds}

  defp typed(attrs, nil), do: attrs

  defp typed(attrs, kind) do
    classes = "confluence-information-macro confluence-information-macro-#{kind}"

    case attributes(attrs, "class") do
      nil -> attrs ++ [{"class", classes}]
      existing -> List.keyreplace(attrs, "class", 0, {"class", existing <> " " <> classes})
    end
  end

  # The badge is an empty span, as in the export view: the glyph is the
  # stylesheet's, so the same rules draw a typed panel and an information macro.
  # It sits beside the body, not inside it, exactly where the real macro carries
  # its own — the body's own margins are what keep a card its own height.
  defp badge(children, nil), do: children

  defp badge(children, _kind) do
    [{"span", [{"class", "confluence-information-macro-icon"}], []} | children]
  end

  defp panel?(attrs), do: class?(attrs, "panel")

  defp class?(attrs, name) do
    attrs
    |> attributes("class")
    |> to_string()
    |> String.split()
    |> Enum.member?(name)
  end

  defp attributes(attrs, key) do
    case List.keyfind(attrs, key, 0) do
      {_key, value} -> value
      nil -> nil
    end
  end
end
