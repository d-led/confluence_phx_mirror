defmodule ConfluencePhxMirror.Confluence.PeopleSource do
  @moduledoc """
  The demo snapshot, plus the one endpoint a face is read from.

  A live site answers for a person — a display name and an avatar — and that is
  the only thing the demo snapshot cannot do, because it carries no people
  endpoint at all. A run over it therefore visits nobody.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @impl true
  def person(_account_id, _opts) do
    {:ok,
     %{
       display_name: "Jane Doe",
       avatar: %{body: <<137, 80, 78, 71, 13, 10, 26, 10>>, media_type: "image/png"}
     }}
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
