defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.RecentlyUpdated do
  @moduledoc """
  *Recently Updated*: what changed last, across the mirror or one space.

      <div class="mirror-macro" data-macro="recently-updated"
           data-limit="10" data-spaces="ENG" data-labels="runbook"></div>

  "The last ten runbooks anyone touched" is a query, and the mirror already has
  one — the parser behind its search box — so the marker is turned into the CQL a
  person would have written and answered by the content port, which narrows it to
  what this page's readers may open.

  Blog posts are included, as they are in Confluence: the week's announcements are
  exactly what a space home page puts this macro up to show.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    case context.source.search(context.page, query(attrs)) do
      {:ok, []} -> [Nodes.empty("Nothing has been updated yet.")]
      {:ok, pages} -> [Nodes.heading("Recently updated"), Nodes.page_list(pages)]
      {:error, reason} -> [Nodes.notice("This macro's query cannot be answered: " <> reason)]
    end
  end

  defp query(attrs) do
    [filters(attrs), "order by lastmodified desc", "limit #{limit(attrs)}"]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # A page and a blog post are both "content somebody updated"; a comment on a
  # page is not, and neither is an attachment, so the query always says so —
  # which also means it is never a query with no filter at all, and the parser
  # can always answer it.
  defp filters(attrs) do
    [
      membership("space", Attributes.list(attrs, "spaces")),
      membership("label", Attributes.list(attrs, "labels")),
      "type in (page, blogpost)"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  defp limit(attrs), do: Attributes.int(attrs, "limit", 10, 1..50)

  defp membership(_field, []), do: nil

  defp membership(field, values), do: "#{field} in (#{Enum.map_join(values, ", ", &value/1)})"

  # A plain word goes in bare; anything else is quoted, so a space key and a label
  # with a space in it read the same to the parser. What neither form can say —
  # a value with a quote in it — is the parser's error to report, and the macro
  # shows it rather than guessing.
  defp value(word) do
    if String.match?(word, ~r/^[A-Za-z0-9_.-]+$/u), do: word, else: ~s("#{word}")
  end
end
