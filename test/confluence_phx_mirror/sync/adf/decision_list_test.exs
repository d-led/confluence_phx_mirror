defmodule ConfluencePhxMirror.Sync.Adf.DecisionListTest do
  @moduledoc """
  *Decisions* keep the state Confluence's HTML drops.

  A decision list is an ADF node, not a macro, and both representations the API
  offers — `export_view` and `view` — carry only its fallback:

      <ul class="decision-list"><li>Track decisions with a visible record.</li></ul>

  The state survives in the document, and the storage format *is* that document,
  so these specs give the repair the two halves of one real page.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.Adf

  # Taken from the site: the same decision in storage and in export view.
  @storage """
  <ac:adf-extension><ac:adf-node type="decision-list"><ac:adf-node type="decision-item"><ac:adf-attribute key="state">DECIDED</ac:adf-attribute><ac:adf-content>Track decisions with a visible record.</ac:adf-content></ac:adf-node></ac:adf-node><ac:adf-fallback><ul class="decision-list"><li>Track decisions with a visible record.</li></ul></ac:adf-fallback></ac:adf-extension>
  """

  @html ~s(<ul class="decision-list"><li>Track decisions with a visible record.</li></ul>)

  test "a decision keeps the state the export view dropped" do
    assert repaired(@html, @storage) ==
             ~s(<ul class="decision-list"><li data-decision-state="decided">Track decisions with a visible record.</li></ul>)
  end

  test "each list keeps the state of its own items" do
    html =
      ~s(<ul class="decision-list"><li>Ship it.</li></ul><ul class="decision-list"><li>Revisit it.</li></ul>)

    assert repaired(html, items(["DECIDED", "OPEN"])) ==
             ~s(<ul class="decision-list"><li data-decision-state="decided">Ship it.</li></ul><ul class="decision-list"><li data-decision-state="open">Revisit it.</li></ul>)
  end

  test "a page with no decision list is left as Confluence drew it" do
    assert repaired(~s(<p>Nothing to decide.</p>), @storage) == ~s(<p>Nothing to decide.</p>)
  end

  test "a body that carries no storage is left as Confluence drew it" do
    assert repaired(@html, nil) == @html
  end

  test "repairing twice changes nothing" do
    once = repaired(@html, @storage)

    assert repaired(once, @storage) == once
  end

  defp repaired(html, storage) do
    html
    |> Floki.parse_fragment!()
    |> Adf.repair(%{storage: storage})
    |> Floki.raw_html()
  end

  defp items(states) do
    states
    |> Enum.map(fn state ->
      ~s(<ac:adf-node type="decision-list"><ac:adf-node type="decision-item"><ac:adf-attribute key="state">#{state}</ac:adf-attribute><ac:adf-content>x</ac:adf-content></ac:adf-node></ac:adf-node>)
    end)
    |> Enum.join()
  end
end
