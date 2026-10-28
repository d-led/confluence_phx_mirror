defmodule ConfluencePhxMirror.Sync.VendorMacros.Adaptavist do
  @moduledoc """
  Adaptavist's *Content Formatting* macros: tabs, tooltips and LaTeX.

  Tabs and tooltips are pure markup once you know the parameters — a
  `<details>` per tab and a `title` attribute per tooltip — so both survive
  without a line of JavaScript.

  The LaTeX block keeps its *source*, in a `pre`, and says so. Typesetting
  mathematics server-side would mean shipping a renderer for a format the mirror
  otherwise never touches, and a page that shows its formula's source is more
  useful than an apology; what must not happen is a silent empty box.
  """

  @behaviour ConfluencePhxMirror.Sync.VendorMacros.Extension

  @impl true
  def draw(%{name: "tabs", body: body}) do
    [{"div", [{"class", "mirror-tabs"}], body}]
  end

  def draw(%{name: "tab", parameters: parameters, body: body}) do
    [
      {"details", [{"class", "mirror-tab"}, {"open", "open"}],
       [{"summary", [], [Map.get(parameters, "title", "Tab")]} | body]}
    ]
  end

  # A tooltip is an attribute on any inline content; with no body of its own the
  # hint *is* the content, which is how the macro reads on a page.
  def draw(%{name: "tooltip", parameters: parameters, body: body}) do
    hint = Map.get(parameters, "title", Map.get(parameters, "text", ""))

    contents = if body == [], do: [hint], else: body
    [{"span", [{"class", "mirror-tooltip"}, {"title", hint}], contents}]
  end

  def draw(%{name: "latex-block", parameters: parameters, body: body}) do
    [
      {"div", [{"class", "mirror-latex"}],
       [
         {"p", [{"class", "mirror-dynamic-notice"}],
          ["The formula's source, as Confluence stored it. The mirror does not typeset LaTeX."]},
         {"pre", [], [source(parameters, body)]}
       ]}
    ]
  end

  defp source(parameters, body) do
    case Map.get(parameters, "body", "") do
      "" -> Floki.text(body)
      stored -> stored
    end
  end
end
