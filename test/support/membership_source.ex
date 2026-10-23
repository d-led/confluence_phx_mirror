defmodule ConfluencePhxMirror.Confluence.MembershipSource do
  @moduledoc """
  The demo snapshot as a Confluence Cloud site answers today.

  Cloud no longer serves "who is in this group" (`/group/{name}/member` is
  gone), so this source leaves `group_members/2` out and answers the other
  direction instead — which groups one account belongs to.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @impl true
  def groups_of_account(_account_id, _opts), do: {:ok, ["mirrored-group"]}

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
