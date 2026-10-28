defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.BlogPosts do
  @moduledoc """
  *Blog Posts*: the space's posts, newest first.

      <div class="mirror-macro" data-macro="blog-posts" data-limit="5"></div>
      <div class="mirror-macro" data-macro="blog-posts" data-spaces="ENG" data-labels="release"></div>

  A blog post is a page of type `blogpost`, so the macro is the question
  *Recently Updated* already asks with a different type and order: the content
  port answers it, narrowed to the posts this page's readers may open.

  Confluence can also point the macro at particular posts by title or id. That is
  a list of content rather than a filter, and the mirror has no answer for it, so
  a marker that names posts says so instead of quietly listing something else.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Listing, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    if named?(attrs) do
      [Nodes.notice("This macro names particular posts, which the mirror cannot follow.")]
    else
      list(query(attrs), context)
    end
  end

  defp list(query, context) do
    case context.source.search(context.page, query) do
      {:ok, []} -> [Nodes.empty("This space has no blog posts yet.")]
      {:ok, posts} -> [Nodes.heading("Blog posts"), Nodes.page_list(posts)]
      {:error, reason} -> [Nodes.notice("This macro's query cannot be answered: " <> reason)]
    end
  end

  # `type` is always there, so the query is never one with no filter at all and
  # the parser can always answer it.
  defp query(attrs) do
    [
      filters(attrs),
      "order by created desc",
      "limit #{Attributes.int(attrs, "limit", 5, 1..50)}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp filters(attrs) do
    [Listing.filters(attrs), "type = blogpost"]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" and ")
  end

  defp named?(attrs), do: attrs |> Map.get("content", "") |> String.trim() != ""
end
