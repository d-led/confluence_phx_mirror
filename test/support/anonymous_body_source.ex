defmodule ConfluencePhxMirror.Confluence.AnonymousBodySource do
  @moduledoc """
  A source whose pages carry *both* renderings, as the site's do.

  Confluence answers with `body.export_view` — what a signed-in reader gets — and
  `body.anonymous_export_view` — the same page for somebody who never signed in,
  without the names and faces. The demo snapshot has only the first, so a test
  about *which* one the mirror keeps needs a source that offers the choice: each
  page says which rendering it is in its own words.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  defdelegate spaces(opts), to: DemoSource

  @impl true
  defdelegate comments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachment_data(attachment, opts), to: DemoSource

  @impl true
  defdelegate changed_since(since, opts), to: DemoSource

  @impl true
  def pages(space_key, opts) do
    with {:ok, pages} <- DemoSource.pages(space_key, opts) do
      {:ok, Enum.map(pages, &both_renderings/1)}
    end
  end

  @impl true
  def page(confluence_id, opts) do
    with {:ok, page} <- DemoSource.page(confluence_id, opts) do
      {:ok, both_renderings(page)}
    end
  end

  defp both_renderings(%{body: body} = page) do
    %{
      page
      | body:
          Map.merge(body, %{
            export_view: "<p>signed-in copy of page #{page.id}</p>",
            anonymous_export_view: "<p>anonymous copy of page #{page.id}</p>"
          })
    }
  end
end
