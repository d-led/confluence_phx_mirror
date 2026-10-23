defmodule ConfluencePhxMirror.Mirror.URLs do
  @moduledoc """
  Canonical mirror URLs.

  Kept independent of `Phoenix` so that the sync pipeline (which has no
  connection) can build exactly the same links the web layer serves.
  """

  @doc "Pretty path of a mirrored page.

  Confluence drops the title segment when a title has nothing usable in it (a
  Cyrillic or CJK title), and so does this: the id alone is the URL.
  "
  def page_path(space_key, confluence_id, slug) do
    with_slug("/spaces/#{encode_segment(space_key)}/pages/#{confluence_id}", slug)
  end

  @doc "Path of a mirrored space."
  def space_path(space_key), do: "/spaces/#{encode_segment(space_key)}"

  @doc "The space's icon, served from the blob store."
  def space_icon_path(space_key), do: space_path(space_key) <> "/icon"

  @doc "Space overview: the catalog view of one space."
  def space_overview_path(space_key), do: space_path(space_key) <> "/overview"

  @doc "Every page of a space, archived content included."
  def space_pages_path(space_key), do: space_path(space_key) <> "/pages"

  @doc "Blog posts of a space."
  def space_blog_path(space_key), do: space_path(space_key) <> "/blog"

  @doc "Attachments of every page in a space."
  def space_attachments_path(space_key), do: space_path(space_key) <> "/attachments"

  @doc "A single blog post, mirroring Confluence's blog URL shape."
  def blog_post_path(space_key, confluence_id, slug) do
    with_slug(space_blog_path(space_key) <> "/#{confluence_id}", slug)
  end

  @doc "Canonical URL of anything the mirror stores as content."
  def content_path(space_key, %{type: "blogpost", confluence_id: id, slug: slug}) do
    blog_post_path(space_key, id, slug)
  end

  def content_path(space_key, %{confluence_id: id, slug: slug}) do
    page_path(space_key, id, slug)
  end

  @doc "The space directory."
  def spaces_path, do: "/spaces"

  @doc "Path of all pages carrying a label."
  def label_path(name), do: "/labels/#{encode_segment(name)}"

  @doc "The label catalog."
  def labels_path, do: "/labels"

  @doc "The people directory."
  def people_path, do: "/people"

  @doc "One person's contributions."
  def person_path(account_id), do: "/people/#{encode_segment(account_id)}"

  @doc "Recently changed content across the mirror."
  def recent_path, do: "/recent"

  @doc "Download path of a mirrored attachment."
  def attachment_path(space_key, page_confluence_id, attachment_confluence_id, filename) do
    "/attachments/#{encode_segment(space_key)}/#{page_confluence_id}/" <>
      "#{attachment_confluence_id}/#{encode_segment(filename)}"
  end

  defp with_slug(base, slug) do
    case to_string(slug || "") do
      "" -> base
      slug -> base <> "/" <> encode_segment(slug)
    end
  end

  # `+` is legal in a path segment and is how Confluence separates the words of
  # a title, so it stays raw instead of becoming `%2B`.
  defp encode_segment(segment) do
    segment
    |> to_string()
    |> URI.encode(&(URI.char_unreserved?(&1) or &1 == ?+))
  end
end
