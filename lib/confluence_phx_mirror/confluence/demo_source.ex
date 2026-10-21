defmodule ConfluencePhxMirror.Confluence.DemoSource do
  @moduledoc """
  Offline source backed by `ConfluencePhxMirror.Confluence.DemoContent`.

  It behaves like a Confluence site: spaces, pages with ancestors, comments,
  attachment bytes and incremental changes. The rest of the application cannot
  tell the difference between this source and the HTTP source.

  The snapshot is a read-only constant. The mirror never writes content; pages
  change only when a sync reads a different snapshot from the source.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoContent

  @impl true
  def name, do: "confluence-demo"

  @impl true
  def kind, do: :demo

  @impl true
  def spaces(_opts), do: {:ok, DemoContent.spaces()}

  @impl true
  def pages(space_key, _opts) do
    pages =
      DemoContent.pages()
      |> Enum.filter(&(&1.space_key == space_key))
      |> Enum.map(&present/1)

    {:ok, pages}
  end

  @impl true
  def page(confluence_id, _opts) do
    case Enum.find(DemoContent.pages(), &(&1.id == confluence_id)) do
      nil -> {:error, :not_found}
      page -> {:ok, present(page)}
    end
  end

  @impl true
  def comments(confluence_id, _opts) do
    comments =
      DemoContent.comments()
      |> Enum.filter(&(&1.page_id == confluence_id))

    {:ok, comments}
  end

  @impl true
  def restrictions(confluence_id, _opts) do
    {:ok, Map.get(DemoContent.page_restrictions(), confluence_id, [])}
  end

  @impl true
  def space_permissions(space_key, _opts) do
    {:ok, Map.get(DemoContent.space_permissions(), space_key, [])}
  end

  @impl true
  def group_members(group_name, _opts) do
    members =
      DemoContent.group_members()
      |> Enum.find_value([], fn {name, members} ->
        if String.downcase(name) == String.downcase(group_name), do: members
      end)

    {:ok, members}
  end

  @impl true
  def attachments(confluence_id, _opts) do
    attachments =
      DemoContent.attachments()
      |> Enum.filter(&(&1.page_id == confluence_id))
      |> Enum.map(&Map.drop(&1, [:content]))

    {:ok, attachments}
  end

  @impl true
  def attachment_data(attachment, _opts) do
    case Enum.find(DemoContent.attachments(), &(&1.id == attachment.id)) do
      nil -> {:error, :not_found}
      %{content: content} -> {:ok, content}
    end
  end

  @impl true
  def changed_since(since, _opts) do
    pages =
      DemoContent.pages()
      |> Enum.map(&present/1)
      |> Enum.filter(&(DateTime.compare(&1.updated_at, since) == :gt))

    {:ok, pages}
  end

  defp present(page) do
    Map.put(page, :ancestors, ancestors(page.id, DemoContent.pages()))
  end

  defp ancestors(page_id, pages, acc \\ []) do
    case Enum.find(pages, &(&1.id == page_id)) do
      nil ->
        acc

      %{parent_id: nil} ->
        acc

      %{parent_id: parent_id} ->
        ancestors(parent_id, pages, [parent_id | acc])
    end
  end
end
