defmodule ConfluencePhxMirror.Sync.MacroPlaceholder do
  @moduledoc """
  The widget every macro gets that the mirror cannot draw.

  A macro it cannot draw is no reason to lose what the page says: a vendor macro
  is usually a container, so the mirror keeps the body it wrapped and puts the
  widget in front of it. The wording says what is missing — the macro's own
  output, which the source did not render either — rather than promising an
  implementation no mirror can make. A macro arrives unexpanded when
  Confluence itself could not render it without a browser, a Connect/Forge app or
  the reader's session, so its answer was never in the payload.

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
         {"p", [], ["The mirror does not draw this macro."]},
         {"p", [], [sentence(label) | origin(Keyword.get(opts, :url))]}
       ]}
    ]
  end

  # The labels are written as they are said mid-sentence ("a Jira issues
  # search"); at the start of the line they take a capital.
  defp sentence(label) do
    label |> String.split_at(1) |> then(fn {first, rest} -> String.upcase(first) <> rest end)
  end

  defp origin(nil), do: ["."]

  defp origin(url), do: [" — see ", {"a", [{"href", url}], ["the original page"]}, "."]
end
