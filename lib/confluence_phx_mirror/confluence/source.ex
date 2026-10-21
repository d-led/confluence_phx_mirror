defmodule ConfluencePhxMirror.Confluence.Source do
  @moduledoc """
  A source of Confluence content.

  The sync pipeline only talks to this behaviour, which keeps it independent of
  *how* content arrives:

    * `ConfluencePhxMirror.Confluence.HttpSource` – Confluence REST API
    * `ConfluencePhxMirror.Confluence.DemoSource` – bundled sample snapshot

  All functions return plain maps ("DTOs") shaped like the Confluence REST API,
  so both sources exercise exactly the same ingestion code.

  ## Page DTO

      %{
        id: 1002,
        type: "page" | "blogpost",
        status: "current" | "draft" | "archived",
        title: "Architecture Overview",
        space_key: "ENG",
        parent_id: 1001 | nil,
        ancestors: [1000, 1001],
        version: %{number: 7, message: "...", when: DateTime.t(), by: %{display_name: "...", account_id: "..."}},
        body: %{storage: "<p>...</p>", export_view: "<p>...</p>"},
        labels: ["architecture", "howto"],
        url: "https://site.atlassian.net/wiki/spaces/ENG/pages/1002/...",
        created_at: DateTime.t(),
        updated_at: DateTime.t()
      }

  ## Space DTO

      %{key: "ENG", name: "Engineering", type: "global", description: "...",
        homepage_id: 1000, url: "https://site.atlassian.net/wiki/spaces/ENG"}

  ## Attachment DTO

      %{id: 9001, page_id: 1002, filename: "diagram.svg",
        media_type: "image/svg+xml", byte_size: 1234, version: 2,
        download_url: "/download/attachments/1002/diagram.svg",
        updated_at: DateTime.t()}

  ## Comment DTO

      %{id: 3001, page_id: 1001, parent_id: nil, author: "Jane Doe",
        body_export: "<p>...</p>", created_at: DateTime.t(), url: "..."}
  """

  @type page :: map()
  @type space :: map()
  @type attachment :: map()
  @type comment :: map()

  @doc "Human readable source name, recorded on every sync run."
  @callback name() :: String.t()

  @doc "All spaces the mirror is configured to import."
  @callback spaces(keyword()) :: {:ok, [space()]} | {:error, term()}

  @doc "All pages (and blog posts) of one space, with bodies expanded."
  @callback pages(space_key :: String.t(), keyword()) :: {:ok, [page()]} | {:error, term()}

  @doc "One page by its Confluence id."
  @callback page(confluence_id :: integer(), keyword()) :: {:ok, page()} | {:error, term()}

  @doc "Comments of a page, including replies."
  @callback comments(confluence_id :: integer(), keyword()) ::
              {:ok, [comment()]} | {:error, term()}

  @doc "Attachment metadata of a page."
  @callback attachments(confluence_id :: integer(), keyword()) ::
              {:ok, [attachment()]} | {:error, term()}

  @doc "Streams the bytes of one attachment."
  @callback attachment_data(attachment(), keyword()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Pages changed since `since`, for incremental pulls.

  Sources without incremental support can implement this by returning
  `{:error, :not_supported}`; the scheduler then falls back to a snapshot.
  """
  @callback changed_since(DateTime.t(), keyword()) :: {:ok, [page()]} | {:error, term()}

  @optional_callbacks changed_since: 2

  @doc "The configured source module."
  def source do
    Application.get_env(
      :confluence_phx_mirror,
      :source,
      ConfluencePhxMirror.Confluence.DemoSource
    )
  end
end
