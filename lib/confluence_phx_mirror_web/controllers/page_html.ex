defmodule ConfluencePhxMirrorWeb.PageHTML do
  @moduledoc "Templates for the reader-facing mirror."

  use ConfluencePhxMirrorWeb, :html

  import ConfluencePhxMirrorWeb.MirrorComponents
  import ConfluencePhxMirrorWeb.UIComponents

  alias ConfluencePhxMirrorWeb.Time

  @excerpt_length 200

  @doc """
  The opening of a page's own words, for a feed that has one line to spare.

  `body_text` is the plain text search already keeps, so a list that reads whole
  rows pays nothing extra for it. Whitespace collapses, because a row cannot show
  a paragraph's layout, and a cut gets an ellipsis so it never reads as a
  sentence the author stopped writing.
  """
  def excerpt(nil), do: ""

  def excerpt(text) when is_binary(text) do
    collapsed = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(collapsed) > @excerpt_length do
      String.slice(collapsed, 0, @excerpt_length) <> "…"
    else
      collapsed
    end
  end

  embed_templates "page_html/*"
end
