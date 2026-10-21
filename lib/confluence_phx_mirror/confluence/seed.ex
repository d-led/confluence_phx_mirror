defmodule ConfluencePhxMirror.Confluence.Seed do
  @moduledoc """
  Copies the bundled demo snapshot into a real Confluence site.

  This is the only code in the application that *writes* to Confluence, and it
  is deliberately timid:

    * it never runs by itself — only `mix confluence.seed` calls it;
    * the default is a dry run that prints the plan and touches nothing;
    * it only creates pages that do not exist yet, matched by title inside one
      space, so running it twice is safe;
    * every page it creates carries the `confluence-mirror-seed` label; a page
      with the same title that lacks that label belongs to a human and is left
      alone — never overwritten, never deleted;
    * it refuses to start unless the API token's account can administer the
      target space, so a reader token cannot spray content into a site.

  The seeded pages are ordinary Confluence pages: the mirror then syncs them like
  any other content, which is what makes them a useful test of the real
  pipeline.
  """

  alias ConfluencePhxMirror.Confluence.{DemoContent, HttpSource}

  @label "confluence-mirror-seed"

  @typedoc "What the seeder intends to do with one page."
  @type decision :: %{
          title: String.t(),
          action: :create | :exists | :foreign,
          page_id: integer() | nil
        }

  @doc "The label marking a page as belonging to the seeder."
  def label, do: @label

  @doc """
  What the seeder would do, without writing anything.

  Returns one decision per demo page of `space_key`, in creation order.
  """
  @spec plan(String.t()) :: {:ok, [decision()]} | {:error, term()}
  def plan(space_key) do
    with {:ok, existing} <- existing_pages(space_key) do
      {:ok, decide(candidates(space_key), existing)}
    end
  end

  @doc """
  Creates the missing demo pages in `space_key`.

  Refuses to run when the account cannot administer the space, and stops at the
  first refused write instead of hammering the site.
  """
  @spec run(String.t()) :: {:ok, [decision()]} | {:error, term()}
  def run(space_key) do
    with :ok <- ensure_admin(space_key),
         {:ok, existing} <- existing_pages(space_key) do
      create_missing(candidates(space_key), existing, space_key)
    end
  end

  @doc """
  Decides per candidate page whether it has to be created.

  Pure on purpose: the rules that protect a human's content deserve tests that
  never touch a Confluence site.
  """
  @spec decide([map()], %{String.t() => %{id: integer(), ours?: boolean()}}) :: [decision()]
  def decide(pages, existing) do
    Enum.map(pages, fn page ->
      case Map.get(existing, page.title) do
        nil -> %{title: page.title, action: :create, page_id: nil}
        %{id: id, ours?: true} -> %{title: page.title, action: :exists, page_id: id}
        %{id: id} -> %{title: page.title, action: :foreign, page_id: id}
      end
    end)
  end

  @doc "Demo pages of one space, parents before children."
  def candidates(space_key) do
    DemoContent.pages()
    |> Enum.filter(&(&1.space_key == space_key))
    |> Enum.sort_by(&depth/1)
  end

  defp depth(%{ancestors: ancestors}) when is_list(ancestors), do: length(ancestors)
  defp depth(_page), do: 0

  defp create_missing(pages, existing, space_key) do
    result =
      Enum.reduce_while(pages, {:ok, [], existing}, fn page, {:ok, done, index} ->
        case decide([page], index) do
          [%{action: :create}] ->
            case create(space_key, page, index) do
              {:ok, id} ->
                decision = %{title: page.title, action: :create, page_id: id}
                index = Map.put(index, page.title, %{id: id, ours?: true})
                {:cont, {:ok, [decision | done], index}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end

          [decision] ->
            {:cont, {:ok, [decision | done], index}}
        end
      end)

    case result do
      {:ok, decisions, _index} -> {:ok, Enum.reverse(decisions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create(space_key, page, index) do
    body = %{
      type: "page",
      title: page.title,
      space: %{key: space_key},
      body: %{storage: %{value: page.body.storage, representation: "storage"}}
    }

    with {:ok, created} <- HttpSource.json(:post, "/content", with_parent(body, page, index)),
         {:ok, _} <- add_label(created["id"]) do
      {:ok, created["id"]}
    end
  end

  defp with_parent(body, page, index) do
    case parent_id(page, index) do
      nil -> body
      id -> Map.put(body, :ancestors, [%{id: id}])
    end
  end

  # The demo page knows its parent by demo id; Confluence needs the id it gave
  # the parent, which is the id stored under the parent's title.
  defp parent_id(%{parent_id: nil}, _index), do: nil

  defp parent_id(%{parent_id: demo_parent}, index) do
    with %{title: title} <- Enum.find(DemoContent.pages(), &(&1.id == demo_parent)),
         %{id: id} <- Map.get(index, title) do
      id
    else
      _ -> nil
    end
  end

  defp add_label(id) do
    HttpSource.json(:post, "/content/#{id}/label", [%{prefix: "global", name: @label}])
  end

  defp existing_pages(space_key) do
    path =
      "/content?spaceKey=#{space_key}&type=page&limit=500&expand=metadata.labels"

    case HttpSource.json(:get, path) do
      {:ok, %{"results" => results}} -> {:ok, to_index(results)}
      {:ok, _other} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_index(results) do
    Map.new(results, fn page ->
      {page["title"], %{id: page["id"], ours?: seed_label?(page)}}
    end)
  end

  defp seed_label?(page) do
    labels = get_in(page, ["metadata", "labels", "results"]) || []
    Enum.any?(labels, &(&1["name"] == @label))
  end

  # Only a space administrator is shown the space's permission list, so a
  # non-empty list is the check: no admin, no seeding.
  defp ensure_admin(space_key) do
    case HttpSource.json(:get, "/space/#{space_key}?expand=permissions") do
      {:ok, %{"permissions" => [_ | _]}} -> :ok
      {:ok, _without_permissions} -> {:error, :not_admin}
      {:error, :not_found} -> {:error, :not_admin}
      {:error, {:forbidden, _}} -> {:error, :not_admin}
      {:error, reason} -> {:error, reason}
    end
  end
end
