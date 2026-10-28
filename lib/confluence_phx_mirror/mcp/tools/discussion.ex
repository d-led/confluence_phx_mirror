defmodule ConfluencePhxMirror.Mcp.Tools.Discussion do
  @moduledoc """
  The material around a page: its comments, its labels and its files.

  All three take a page reference and go through `Pages.resolve/2`, so a reader
  who may not open the page gets the same "not mirrored" answer here as
  everywhere else — a comment or an attachment must not become a side door to
  content behind a restriction.
  """

  alias ConfluencePhxMirror.Mcp.{Args, Links, Markdown}
  alias ConfluencePhxMirror.Mcp.Tools.Pages
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, URLs}
  alias ConfluencePhxMirror.Publishing

  @doc "`confluence_get_comments`: a page's comments and replies, oldest first."
  def comments(args, scope) do
    with {:ok, page} <- Pages.resolve(args, scope),
         {:ok, markdown?} <- Args.boolean(args, "convert_to_markdown", true) do
      comments = Mirror.comments(page)
      # A comment's `parent_id` is a local row id; a caller thinks in the ids
      # the mirror serves content by, so the parent is translated here.
      parents = Map.new(comments, &{&1.id, &1.confluence_id})

      {:ok,
       %{
         text: comments_text(page, comments, parents, markdown?),
         structured: %{
           "page" => Pages.summary(page),
           "comments" => Enum.map(comments, &comment_summary(&1, parents))
         }
       }}
    end
  end

  @doc "`confluence_get_labels`: the labels a page carries."
  def labels(args, scope) do
    with {:ok, page} <- Pages.resolve(args, scope) do
      labels = page.labels || []

      {:ok,
       %{
         text: labels_text(page, labels),
         structured: %{
           "page" => Pages.summary(page),
           "labels" =>
             Enum.map(labels, fn name ->
               %{"name" => name, "prefix" => "global", "url" => label_url(name)}
             end)
         }
       }}
    end
  end

  @doc "`confluence_get_attachments`: a page's files, without their bytes."
  def attachments(args, scope) do
    with {:ok, page} <- Pages.resolve(args, scope) do
      files = Mirror.attachments(page)

      {:ok,
       %{
         text: attachments_text(page, files),
         structured: %{
           "page" => Pages.summary(page),
           "attachments" => Enum.map(files, &attachment_summary(page, &1))
         }
       }}
    end
  end

  defp comments_text(page, [], _parents, _markdown?) do
    "#{page.title} (id #{page.confluence_id}) has no comments."
  end

  defp comments_text(page, comments, parents, markdown?) do
    "Comments on #{page.title} (id #{page.confluence_id}) — #{length(comments)}:\n\n" <>
      Enum.map_join(Enum.with_index(comments, 1), "\n\n", fn {comment, index} ->
        "### #{index}. #{Publishing.byline(comment.author_name) || "Unknown"} — " <>
          "#{Pages.iso(comment.external_created_at) || "unknown"}" <>
          " (comment #{comment.confluence_id})\n" <>
          reply_to(comment, parents) <>
          body(comment, markdown?)
      end)
  end

  defp reply_to(comment, parents) do
    case parents[comment.parent_id] do
      nil -> ""
      parent -> "Reply in thread #{parent}.\n\n"
    end
  end

  defp body(comment, true), do: Markdown.comment(comment)
  defp body(comment, false), do: comment.body_export || ""

  defp comment_summary(comment, parents) do
    %{
      "id" => to_string(comment.confluence_id),
      "author" => Publishing.byline(comment.author_name),
      "created" => Pages.iso(comment.external_created_at),
      "parent_id" => parents[comment.parent_id] && to_string(parents[comment.parent_id]),
      "url" => comment.external_url
    }
  end

  defp labels_text(page, []) do
    "#{page.title} (id #{page.confluence_id}) carries no labels."
  end

  defp labels_text(page, labels) do
    "Labels on #{page.title} (id #{page.confluence_id}): " <> Enum.join(labels, ", ")
  end

  defp label_url(name), do: ConfluencePhxMirrorWeb.Endpoint.url() <> URLs.label_path(name)

  defp attachments_text(page, []) do
    "#{page.title} (id #{page.confluence_id}) has no attachments."
  end

  defp attachments_text(page, files) do
    "Attachments on #{page.title} (id #{page.confluence_id}) — #{length(files)}:\n\n" <>
      Enum.map_join(files, "\n", fn file ->
        "- #{file.filename} — #{file.media_type}, #{Attachment.human_size(file.byte_size)}\n" <>
          "  #{Links.attachment(page, file)}\n" <>
          "  (the download needs the same credentials as this server)"
      end)
  end

  defp attachment_summary(page, file) do
    %{
      "id" => to_string(file.confluence_id),
      "filename" => file.filename,
      "media_type" => file.media_type,
      "byte_size" => file.byte_size,
      "version" => file.version_number,
      "url" => Links.attachment(page, file)
    }
  end
end
