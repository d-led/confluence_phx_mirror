defmodule ConfluencePhxMirror.Confluence.PersonalSpaceSource do
  @moduledoc """
  Test double for a site where the sync account also has a personal space.

  `DemoSource` has no personal space, so this wrapper adds one — enough to pin
  whether a snapshot imports it.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @personal_key "~557058ABCDEF"

  def personal_key, do: @personal_key

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  def spaces(_opts) do
    {:ok, spaces} = DemoSource.spaces([])

    {:ok,
     spaces ++
       [
         %{
           key: @personal_key,
           name: "Dmitry Ledentsov",
           type: "personal",
           description: "Your personal space",
           homepage_id: nil,
           url: "https://demo.atlassian.net/spaces/#{@personal_key}"
         }
       ]}
  end

  @impl true
  def pages(@personal_key, _opts), do: {:ok, []}
  def pages(space_key, opts), do: DemoSource.pages(space_key, opts)

  @impl true
  defdelegate page(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate comments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachment_data(attachment, opts), to: DemoSource

  @impl true
  defdelegate restrictions(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate space_permissions(space_key, opts), to: DemoSource

  @impl true
  defdelegate group_members(group_name, opts), to: DemoSource
end
