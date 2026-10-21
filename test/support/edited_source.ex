defmodule ConfluencePhxMirror.Confluence.EditedSource do
  @moduledoc """
  Test double standing in for Confluence *after* someone edited page 1002 there.

  The mirror is read-only, so the only way a page changes is a sync that reads a
  new snapshot from upstream. This source returns the demo snapshot with one
  page edited, which is exactly what Confluence would serve after an edit.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @edited_page_id 1002
  @edit_note "Clarified the pipeline"
  @edit_body "<p>Edited in Confluence: the pipeline retries before it fails.</p>"

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  defdelegate spaces(opts), to: DemoSource

  @impl true
  defdelegate pages(space_key, opts), to: DemoSource

  @impl true
  defdelegate comments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachment_data(attachment, opts), to: DemoSource

  @impl true
  defdelegate changed_since(since, opts), to: DemoSource

  @impl true
  def page(@edited_page_id, _opts) do
    {:ok, page} = DemoSource.page(@edited_page_id, [])

    edited_at = DateTime.utc_now() |> DateTime.truncate(:second)
    body = page.body.export_view <> @edit_body

    {:ok,
     %{
       page
       | version: %{
           page.version
           | number: page.version.number + 1,
             message: @edit_note,
             when: edited_at
         },
         body: %{storage: body, export_view: body},
         updated_at: edited_at
     }}
  end

  def page(confluence_id, opts), do: DemoSource.page(confluence_id, opts)

  @doc "The change note the edited page carries upstream."
  def edit_note, do: @edit_note
end
