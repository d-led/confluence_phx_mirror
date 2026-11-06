defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.LiveSearch do
  @moduledoc """
  *Live search*: the site's search box, answering as a reader types.

      <ac:structured-macro ac:name="livesearch" ac:schema-version="1" />

  The editor stores the macro and nothing else — no query, no filter, no scope —
  because the box it draws asks the site as it goes. A static mirror has search
  of its own and no search-as-you-type index in the page, so the macro becomes
  the way to that search: a line with the mirror's search narrowed to the page's
  own space, and the one that looks at everything.

  The space is the only thing there is to carry, and it is not a guess: it is the
  space the page is in. The search screen keeps its whole state in the URL, so
  the narrowed link opens that same screen with the space already chosen, and a
  reader widens it from there.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Sync.DynamicContent.Context

  @impl true
  def render(_attrs, %Context{space: space}) do
    [{"p", [{"class", "mirror-dynamic-search"}], links(key(space))}]
  end

  defp links(nil), do: ["Search ", link(URLs.search_path(), "the mirror"), "."]

  defp links(space_key) do
    [
      "Search ",
      link(URLs.search_path(space_key), "this space"),
      " or ",
      link(URLs.search_path(), "the whole mirror"),
      "."
    ]
  end

  defp link(href, text),
    do: {"a", [{"href", href}, {"class", "mirror-dynamic-link"}], [text]}

  defp key(%{key: key}) when is_binary(key) and key != "", do: key
  defp key(_space), do: nil
end
