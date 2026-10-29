defmodule ConfluencePhxMirror.Confluence.PagedGroupSource do
  @moduledoc """
  A site that lists its groups and pages through their members.

  This is what Confluence Cloud does today: `/group/{id}/membersByGroupId`
  answers a page of members at a time, for every group the site lists — the
  direction that reaches people who never authored anything and never signed in.
  The demo snapshot answers the rest of the `Source` behaviour.

  The groups it answers with are the default below, or whatever a test put under
  `:paged_group_source` — a second read that names one member fewer is how the
  "they left the group" case is set up.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @default [
    %{
      name: "staff",
      id: "8f14e45f",
      pages: [
        [
          %{account_id: "557058:bert", display_name: "Bert Lindner"},
          %{
            account_id: "557058:birgit",
            display_name: "Birgit Grossmann",
            email: "Birgit@Example.com"
          }
        ],
        [%{account_id: "557058:karsten", display_name: "Karsten Ehms"}]
      ]
    },
    %{
      name: "robot",
      id: "c4ca4238",
      pages: [[%{account_id: "557058:bot", display_name: "Chat"}]]
    }
  ]

  @doc "The groups this source answers with, as a test set them."
  def groups_data, do: Application.get_env(:confluence_phx_mirror, :paged_group_source, @default)

  @impl true
  def groups(_opts), do: {:ok, Enum.map(groups_data(), &Map.take(&1, [:name, :id]))}

  @impl true
  def each_group_member_page(%{name: name}, _opts, sink) do
    %{pages: pages} = Enum.find(groups_data(), &(&1.name == name))

    Enum.each(pages, sink)
    {:ok, pages |> Enum.map(&length/1) |> Enum.sum()}
  end

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  defdelegate web_url(), to: DemoSource

  @impl true
  defdelegate spaces(opts), to: DemoSource

  @impl true
  defdelegate pages(space_key, opts), to: DemoSource

  @impl true
  defdelegate page(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate comments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate restrictions(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate space_permissions(space_key, opts), to: DemoSource

  @impl true
  defdelegate attachments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachment_data(attachment, opts), to: DemoSource

  @impl true
  defdelegate changed_since(since, opts), to: DemoSource
end
