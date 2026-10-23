defmodule ConfluencePhxMirror.Confluence.AccountGoneSource do
  @moduledoc """
  The demo snapshot, except that one Atlassian account is no longer on the site.

  Confluence answers a 404 for an account it does not have, which is the fact
  the mirror has to tell apart from "the site switched this person off".
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @gone "557058:gone"

  @impl true
  def user_status(@gone, _opts), do: {:error, :not_found}

  @impl true
  defdelegate user_status(account_id, opts), to: DemoSource

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
  defdelegate group_members(group_name, opts), to: DemoSource

  @impl true
  defdelegate attachments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachment_data(attachment, opts), to: DemoSource

  @impl true
  defdelegate changed_since(since, opts), to: DemoSource
end
