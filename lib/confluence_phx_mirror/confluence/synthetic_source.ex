defmodule ConfluencePhxMirror.Confluence.SyntheticSource do
  @moduledoc """
  A Confluence site with generated content, for scale work.

  Nothing about it is fetched: spaces, pages and their tree come from
  `ConfluencePhxMirror.Confluence.SyntheticContent`, sized by configuration.

      config :confluence_phx_mirror, ConfluencePhxMirror.Confluence.SyntheticSource,
        spaces: 1000, pages_per_space: 1000

  It reports itself as `:demo` content — it is a generated snapshot bundled with
  the application, not a live site — so the reader UI keeps saying where the
  content came from.

  There are no comments, attachments, restrictions or space permissions: the
  point of the source is a large amount of *pages*, and the read path a page
  view exercises over them.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.SyntheticContent

  @impl true
  def name, do: "confluence-synthetic"

  @impl true
  def kind, do: :demo

  @impl true
  def web_url, do: nil

  @impl true
  def spaces(opts), do: {:ok, SyntheticContent.spaces(opts)}

  @impl true
  def pages(space_key, opts), do: SyntheticContent.pages(space_key, opts)

  @impl true
  def page(confluence_id, opts), do: SyntheticContent.page(confluence_id, opts)

  @impl true
  def comments(_confluence_id, _opts), do: {:ok, []}

  @impl true
  def attachments(_confluence_id, _opts), do: {:ok, []}

  @impl true
  def attachment_data(_attachment, _opts), do: {:error, :not_found}
end
