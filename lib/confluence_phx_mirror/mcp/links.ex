defmodule ConfluencePhxMirror.Mcp.Links do
  @moduledoc """
  Absolute addresses for the tool results.

  A model may be reading this mirror through a client on another machine, so a
  relative path is only half of an address. These are the same paths the UI
  serves — `Mirror.URLs` decides their shape from the slug, and nothing here
  invents a second URL scheme.
  """

  alias ConfluencePhxMirror.Mirror.{Page, Space, URLs}
  alias ConfluencePhxMirrorWeb.Endpoint

  @doc "Public URL of a page or blog post."
  @spec page(Page.t() | map()) :: String.t()
  def page(%{space: %Space{} = space} = page) do
    Endpoint.url() <> URLs.content_path(space.key, page)
  end

  @doc "Public URL of a space overview."
  @spec space(Space.t()) :: String.t()
  def space(%Space{key: key}), do: Endpoint.url() <> URLs.space_path(key)

  @doc "Public URL of a page's attachment download."
  @spec attachment(Page.t(), map()) :: String.t()
  def attachment(%Page{space: %Space{} = space} = page, attachment) do
    Endpoint.url() <>
      URLs.attachment_path(
        space.key,
        page.confluence_id,
        attachment.confluence_id,
        attachment.filename
      )
  end
end
