defmodule ConfluencePhxMirror.Sync.DynamicContent.Nodes do
  @moduledoc """
  The HTML vocabulary macros render with.

  One place for the markup and the classes the stylesheet knows, so a macro that
  is written next year looks like the ones written today without copying a
  `div`. Everything here is a Floki node; the expander serialises the lot.
  """

  alias ConfluencePhxMirror.Mirror.URLs

  @doc "What a macro is about — a line above the listing."
  def heading(text), do: {"p", [{"class", "mirror-dynamic-heading"}], [text]}

  @doc "The macro has nothing to show, and says so."
  def empty(text), do: {"p", [{"class", "mirror-dynamic-empty"}], [text]}

  @doc "The macro cannot be drawn faithfully, and says why."
  def notice(text), do: {"p", [{"class", "mirror-dynamic-notice"}], [text]}

  @doc "A list of pages: title, space and when it was last updated."
  def page_list(pages),
    do: {"ul", [{"class", "mirror-dynamic-list"}], Enum.map(pages, &page_item/1)}

  @doc "One listed page, linked through the reader route."
  def page_item(page) do
    {"li", [],
     [
       {"a",
        [{"href", URLs.content_path(page.space.key, page)}, {"class", "mirror-dynamic-link"}],
        [page.title]},
       {"span", [{"class", "mirror-dynamic-meta"}], [" · #{page.space.key} · #{updated(page)}"]}
     ]}
  end

  defp updated(%{external_updated_at: nil}), do: "unknown date"

  defp updated(%{external_updated_at: at}),
    do: "updated " <> Calendar.strftime(at, "%d %b %Y")
end
