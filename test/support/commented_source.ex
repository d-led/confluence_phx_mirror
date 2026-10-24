defmodule ConfluencePhxMirror.Confluence.CommentedSource do
  @moduledoc """
  Test double standing in for Confluence *after* somebody commented on a page
  there — and pasted a screenshot into the comment.

  Neither event moves the page's own version: the page is still at the version
  the mirror already holds. That is exactly the case an incremental run that
  only asks "which pages changed?" cannot see, so this source is what proves the
  mirror asks about comments and files as well.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @page_id 1002
  @comment_id 7001
  @attachment_id "att7002"
  @filename "screenshot.png"
  @bytes <<137, 80, 78, 71, 13, 10, 26, 10>>
  @body ~s(<p>Looks good to me</p><img src="/wiki/download/thumbnails/7001/screenshot.png?version=1" />)

  @doc "The page the comment was left on."
  def page_id, do: @page_id

  @doc "The comment's id, as Confluence names it."
  def comment_id, do: @comment_id

  @doc "The name of the file pasted into the comment."
  def filename, do: @filename

  @doc "The bytes of that file."
  def bytes, do: @bytes

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  defdelegate spaces(opts), to: DemoSource

  @impl true
  defdelegate pages(space_key, opts), to: DemoSource

  @impl true
  defdelegate page(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate restrictions(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate space_permissions(space_key, opts), to: DemoSource

  @impl true
  defdelegate group_members(group_name, opts), to: DemoSource

  @impl true
  defdelegate user_status(account_id, opts), to: DemoSource

  @impl true
  defdelegate attachments(confluence_id, opts), to: DemoSource

  # Nothing is left in the page window: the page itself did not change. What
  # changed is its child, and only `touched_since/2` knows that.
  @impl true
  def changed_since(since, _opts) when is_struct(since, DateTime), do: {:ok, []}

  @impl true
  def touched_since(_since, _opts), do: {:ok, %{pages: [@page_id], space_attachments: 0}}

  @impl true
  def comments(@page_id, _opts) do
    {:ok, [comment_dto() | demo_comments(@page_id)]}
  end

  def comments(confluence_id, opts), do: DemoSource.comments(confluence_id, opts)

  @impl true
  def attachment_data(%{id: @attachment_id}, _opts), do: {:ok, @bytes}

  def attachment_data(attachment, opts), do: DemoSource.attachment_data(attachment, opts)

  defp demo_comments(page_id) do
    {:ok, comments} = DemoSource.comments(page_id, [])
    comments
  end

  defp comment_dto do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      id: @comment_id,
      page_id: @page_id,
      parent_id: nil,
      author: "Jane Doe",
      author_account_id: "acc-jane",
      body_export: @body,
      version_number: 1,
      created_at: now,
      updated_at: now,
      url: "https://dled.atlassian.net/wiki/spaces/ENG/pages/1002#comment-7001",
      attachments: [file_dto(now)]
    }
  end

  defp file_dto(now) do
    %{
      id: @attachment_id,
      page_id: @page_id,
      comment_id: @comment_id,
      filename: @filename,
      media_type: "image/png",
      byte_size: byte_size(@bytes),
      version: 1,
      download_url: "/download/attachments/#{@comment_id}/#{@filename}",
      updated_at: now
    }
  end
end
