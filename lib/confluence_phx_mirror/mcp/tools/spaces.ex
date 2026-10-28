defmodule ConfluencePhxMirror.Mcp.Tools.Spaces do
  @moduledoc """
  Tools about spaces: what exists, what one contains, and what changed lately.

  `confluence_list_spaces` is the entry point for a caller that does not know a
  key yet; it reads through `Authorization.readable_spaces/2`, so the list is
  the same one the UI's space switcher shows. Everything that takes a
  `space_key` answers "not mirrored" for a space the reader may not open — the
  same answer the HTTP surface gives, for the same reason.
  """

  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Catalog
  alias ConfluencePhxMirror.Mcp.{Args, Links}
  alias ConfluencePhxMirror.Mcp.Tools.Pages
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Publishing

  @doc "`confluence_list_spaces`: the spaces the reader may see."
  def list(args, scope) do
    with {:ok, query} <- Args.optional(args, "query"),
         {:ok, limit} <- Args.integer(args, "limit", default: 25, min: 1, max: 100) do
      spaces = Authorization.readable_spaces(scope, limit: limit, query: query || "")

      {:ok,
       %{
         text: spaces_text(spaces, query),
         structured: %{"spaces" => Enum.map(spaces, &space_summary/1)}
       }}
    end
  end

  @doc "`confluence_get_space`: one space and what a reader can find in it."
  def get(args, scope) do
    with {:ok, key} <- Args.required(args, "space_key") do
      with_space(key, scope, fn space ->
        {:ok,
         %{
           text: space_text(space, scope),
           structured:
             space_summary(space)
             |> Map.put("description", space.description)
             |> Map.put("labels", space.labels || [])
             |> Map.put("pages", Catalog.count_pages(scope, space_id: space.id))
         }}
      end)
    end
  end

  @doc "`confluence_list_blog_posts`: a space's news, newest first."
  def blog_posts(args, scope) do
    with {:ok, key} <- Args.required(args, "space_key"),
         {:ok, limit} <- Args.integer(args, "limit", default: 20, min: 1, max: 100) do
      with_space(key, scope, fn space ->
        posts = Mirror.blog_posts(space.id, limit, filter: Pages.restrict(scope))

        {:ok,
         %{
           text: blog_text(space, posts),
           structured: %{
             "space" => space_summary(space),
             "posts" => Enum.map(posts, &post_summary(&1, space))
           }
         }}
      end)
    end
  end

  @doc "`confluence_get_recent_changes`: content updated most recently."
  def recent(args, scope) do
    with {:ok, key} <- Args.optional(args, "space_key"),
         {:ok, limit} <- Args.integer(args, "limit", default: 20, min: 1, max: 100) do
      case key do
        nil -> recent_in(nil, scope, limit)
        key -> with_space(key, scope, fn space -> recent_in(space, scope, limit) end)
      end
    end
  end

  defp recent_in(space, scope, limit) do
    %{items: pages} =
      Catalog.recent(scope, limit: limit, space_id: space && space.id)

    where = if space, do: " in #{space.name} (#{space.key})", else: ""

    text =
      case pages do
        [] ->
          "No content changed recently#{where} that you may read."

        pages ->
          "Recently updated content#{where}, newest first:\n\n" <>
            Enum.map_join(pages, "\n", fn page ->
              "- #{Pages.iso(page.external_updated_at) || "unknown"} — " <>
                "#{page.title} (id #{page.confluence_id}, #{page.space.key})\n" <>
                "  #{Links.page(page)}"
            end)
      end

    {:ok, %{text: text, structured: %{"changes" => Enum.map(pages, &Pages.summary/1)}}}
  end

  defp with_space(key, scope, fun) do
    space_key = String.upcase(key)

    case Mirror.find_space(space_key) do
      {:ok, space} ->
        if Authorization.can_read_space?(scope, space) do
          fun.(space)
        else
          {:error, "Space #{space_key} is not mirrored."}
        end

      {:error, :not_found} ->
        {:error, "Space #{space_key} is not mirrored."}
    end
  end

  defp spaces_text([], nil), do: "No spaces are mirrored."
  defp spaces_text([], query), do: "No space key or name contains #{inspect(query)}."

  defp spaces_text(spaces, _query) do
    "Spaces you may read — #{length(spaces)}:\n\n" <>
      Enum.map_join(spaces, "\n", fn space ->
        "- #{space.key} — #{space.name}\n  #{Links.space(space)}" <>
          if(space.description, do: "\n  #{space.description}", else: "")
      end)
  end

  defp space_text(space, scope) do
    [
      "# #{space.name} (#{space.key})",
      space.description,
      "- url: #{Links.space(space)}",
      home_page(space),
      "- pages you may read: #{Catalog.count_pages(scope, space_id: space.id)}",
      labels(space)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp home_page(space) do
    case Mirror.get_space_home(space) do
      nil -> nil
      home -> "- home page: #{home.title} (id #{home.confluence_id})"
    end
  end

  defp labels(%{labels: labels}) when labels in [nil, []], do: nil
  defp labels(space), do: "- labels: " <> Enum.join(space.labels, ", ")

  defp space_summary(space) do
    %{"key" => space.key, "name" => space.name, "url" => Links.space(space)}
  end

  defp blog_text(space, []),
    do: "No blog posts in #{space.name} (#{space.key}) that you may read."

  defp blog_text(space, posts) do
    "Blog posts in #{space.name} (#{space.key}) — #{length(posts)}, newest first:\n\n" <>
      Enum.map_join(posts, "\n", fn post ->
        "- #{post.title} (id #{post.confluence_id})" <>
          " — #{Pages.iso(post.external_updated_at) || "unknown"}" <>
          if(post.author_name && not Publishing.anonymise_contributors?(),
            do: " by #{post.author_name}",
            else: ""
          ) <>
          "\n  #{Links.page(Map.put(post, :space, space))}"
      end)
  end

  # `blog_posts/3` selects a handful of columns without the space, so the link
  # is built from the space the caller already has.
  defp post_summary(post, space) do
    %{
      "id" => to_string(post.confluence_id),
      "title" => post.title,
      "type" => post.type,
      "space" => space.key,
      "url" => Links.page(Map.put(post, :space, space)),
      "updated" => Pages.iso(post.external_updated_at),
      "author" => Publishing.byline(post.author_name)
    }
  end
end
