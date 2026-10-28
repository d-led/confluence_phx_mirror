defmodule ConfluencePhxMirror.Sync.MacroPlaceholder do
  @moduledoc """
  The widget every macro gets that the mirror cannot draw yet.

  A macro it cannot draw is no reason to lose what the page says: a vendor macro
  is usually a container, so the mirror keeps the body it wrapped and puts the
  widget in front of it. The wording names the gap as the mirror's — an export
  renderer that does not exist — rather than leaving a reader to wonder whether
  Confluence or the mirror dropped the content.

  It is a `blockquote` on purpose. The Markdown export already turns a quote into
  a `>` block, so the same node that styles as a box on the reader page reads as
  a note in a Markdown or site archive, with no second implementation and no way
  for the two to drift apart.
  """

  @doc """
  The note, and nothing else: the caller keeps the macro's body.

      iex> widget("table-filter", label: "Appfire's table filter", url: "https://x")
      [{"blockquote", [{"class", "mirror-macro-placeholder"}], [_, _]}]
  """
  @spec widget(String.t(), keyword()) :: [Floki.html_node()]
  def widget(name, opts \\ []) do
    label = Keyword.get(opts, :label) || "the #{name} macro"

    [
      {"blockquote", [{"class", "mirror-macro-placeholder"}],
       [
         {"p", [], ["This macro's export renderer is not yet implemented."]},
         {"p", [], [label | origin(Keyword.get(opts, :url))]}
       ]}
    ]
  end

  defp origin(nil), do: ["."]

  defp origin(url), do: [" — see ", {"a", [{"href", url}], ["the original page"]}, "."]
end
