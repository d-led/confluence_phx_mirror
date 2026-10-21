defmodule ConfluencePhxMirror.Confluence.DemoSource do
  @moduledoc """
  Offline source backed by `ConfluencePhxMirror.Confluence.DemoContent`.

  It behaves like a Confluence site: spaces, pages with ancestors, comments,
  attachment bytes, incremental changes and even simulated edits (used by the
  webhook demo). The rest of the application cannot tell the difference between
  this source and the HTTP source.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoContent

  @edits_key {__MODULE__, :edits}

  @impl true
  def name, do: "confluence-demo"

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

  @doc """
  Pretends that a page was edited in Confluence.

  The next sync of that page returns a higher version and an extra change note,
  which is how the webhook demo shows "content changed → mirror updated".
  """
  def simulate_edit(page_id, attrs \\ %{}) do
    edits = Map.put(edits(), page_id, Map.new(attrs))
    :persistent_term.put(@edits_key, edits)
    :ok
  end

  @doc "Removes all simulated edits (tests and demo resets)."
  def reset_edits do
    :persistent_term.put(@edits_key, %{})
    :ok
  end

  defp edits, do: :persistent_term.get(@edits_key, %{})

  defp present(page) do
    page
    |> Map.put(:ancestors, ancestors(page.id, DemoContent.pages()))
    |> apply_edit()
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

  defp apply_edit(page) do
    case Map.get(edits(), page.id) do
      nil ->
        page

      edit ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        revision = Map.get(edit, :revision, 1)
        note = Map.get(edit, :note, "Updated in Confluence; the mirror picked it up.")

        body =
          page.body.export_view <>
            ~s(<div class="panel" style="background-color: #e3fcef; border: 1px solid #57d9a3;"><div class="panelContent"><p><strong>Updated</strong> #{note}</p></div></div>)

        %{
          page
          | version: %{
              page.version
              | number: page.version.number + revision,
                message: note,
                when: now
            },
            body: %{page.body | export_view: body},
            updated_at: now
        }
    end
  end
end
