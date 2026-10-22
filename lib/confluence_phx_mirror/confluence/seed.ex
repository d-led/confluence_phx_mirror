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
    * attachments and comments are matched by filename and body, so a second run
      adds nothing;
    * it refuses to start unless the API token's account can administer the
      target space, so a reader token cannot spray content into a site.

  What it mirrors is the demo's *rich* content, not just page bodies: labels,
  attachment bytes and comments travel too, because that is what the mirror's
  own features (labels, blobs, comments) are exercised by.
  """

  alias ConfluencePhxMirror.Confluence.{DemoContent, HttpSource}

  @label "confluence-mirror-seed"

  @typedoc "What the seeder intends to do with one page, or what it added to it."
  @type decision :: %{
          required(:title) => String.t(),
          required(:action) => :create | :exists | :foreign | :extras,
          required(:page_id) => integer() | nil,
          optional(:detail) => String.t()
        }

  @doc "The label marking a page as belonging to the seeder."
  def label, do: @label

  @doc """
  Which pages the seeder would create, without writing anything.

  `:from` names the demo space(s) to copy: a key, a list, or `"all"`. It
  defaults to `space_key` itself when the demo has such a space, and to `ENG`
  otherwise — real sites rarely use the demo's space keys.
  """
  @spec plan(String.t(), keyword()) :: {:ok, [decision()]} | {:error, term()}
  def plan(space_key, opts \\ []) do
    with {:ok, existing} <- existing_pages(space_key) do
      {:ok, decide(candidates(demo_spaces(opts[:from], space_key)), existing)}
    end
  end

  @doc """
  Creates the missing demo pages, then adds their labels, attachments and
  comments.

  Refuses to run when the account cannot administer the space, and stops at the
  first refused write instead of hammering the site.
  """
  @spec run(String.t(), keyword()) :: {:ok, [decision()]} | {:error, term()}
  def run(space_key, opts \\ []) do
    pages = candidates(demo_spaces(opts[:from], space_key))

    with :ok <- ensure_admin(space_key),
         {:ok, existing} <- existing_pages(space_key),
         {:ok, decisions, index} <- ensure_pages(pages, existing, space_key) do
      {:ok, decisions ++ extras(pages, index)}
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

  @doc "Demo pages of the given spaces, parents before children."
  def candidates(demo_spaces) do
    DemoContent.pages()
    |> Enum.filter(&(&1.space_key in demo_spaces))
    |> Enum.sort_by(&depth/1)
  end

  # Which demo space(s) to copy from.
  defp demo_spaces(nil, space_key) do
    if demo_space?(space_key), do: [space_key], else: ["ENG"]
  end

  defp demo_spaces("all", _space_key), do: DemoContent.spaces() |> Enum.map(& &1.key)

  defp demo_spaces(keys, _space_key) when is_list(keys), do: keys
  defp demo_spaces(key, _space_key) when is_binary(key), do: String.split(key, ",", trim: true)

  defp demo_space?(key), do: Enum.any?(DemoContent.pages(), &(&1.space_key == key))

  defp depth(%{ancestors: ancestors}) when is_list(ancestors), do: length(ancestors)
  defp depth(_page), do: 0

  # Creates what is missing and returns a demo-id -> real-id index for the
  # extras (attachments and comments point at demo page ids).
  defp ensure_pages(pages, existing, space_key) do
    result =
      Enum.reduce_while(pages, {:ok, [], existing}, fn page, {:ok, done, index} ->
        case decide([page], index) do
          [%{action: :create}] ->
            case create(space_key, page, index) do
              {:ok, id} ->
                decision = %{title: page.title, action: :create, page_id: id}
                index = Map.put(index, page.title, %{id: id, ours?: true})
                {:cont, {:ok, [decision | done], index}}

              {:skip, reason} ->
                {:cont,
                 {:ok, [%{title: page.title, action: :skipped, detail: reason} | done], index}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end

          [decision] ->
            {:cont, {:ok, [decision | done], index}}
        end
      end)

    case result do
      {:ok, decisions, index} ->
        {:ok, Enum.reverse(decisions), id_index(pages, index)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp id_index(pages, index) do
    for page <- pages, real = get_in(index, [page.title, :id]), into: %{} do
      {page.id, real}
    end
  end

  defp create(space_key, page, index) do
    body = %{
      type: page.type || "page",
      title: page.title,
      space: %{key: space_key},
      body: %{storage: %{value: page.body.storage, representation: "storage"}}
    }

    with {:ok, created} <- HttpSource.json(:post, "/content", with_parent(body, page, index)),
         {:ok, _} <- add_labels(created["id"], [@label]) do
      {:ok, created["id"]}
    else
      # A space can have blog posts switched off; that page simply is not
      # created, and the rest of the seed carries on.
      {:error, {:http, 400, body}} ->
        if String.contains?(body, "is not enabled in space") do
          {:skip, "#{page.type} is not enabled in this space"}
        else
          {:error, {:http, 400, body}}
        end

      {:error, reason} ->
        {:error, reason}
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

  defp add_labels(_id, []), do: {:ok, 0}

  defp add_labels(id, labels) do
    case HttpSource.json(:post, "/content/#{id}/label", Enum.map(labels, &label_payload/1)) do
      {:ok, _} -> {:ok, length(labels)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp label_payload(name), do: %{prefix: "global", name: name}

  # What a page gained besides its body: labels, files, comments. Runs for pages
  # the seeder owns as well as for ones it just created.
  defp extras(pages, index) do
    Enum.flat_map(pages, fn page ->
      case Map.fetch(index, page.id) do
        {:ok, real_id} -> extras_for(page, real_id)
        :error -> []
      end
    end)
  end

  defp extras_for(page, real_id) do
    with {:ok, labels} <- add_labels(real_id, page.labels),
         {:ok, files} <- upload_attachments(real_id, page.id),
         {:ok, comments} <- add_comments(real_id, page.id),
         total when total > 0 <- labels + files + comments do
      [
        %{
          title: page.title,
          action: :extras,
          page_id: real_id,
          detail: "#{labels} labels, #{files} files, #{comments} comments"
        }
      ]
    else
      _nothing_added_or_error -> []
    end
  end

  defp upload_attachments(real_id, demo_page_id) do
    DemoContent.attachments()
    |> Enum.filter(&(&1.page_id == demo_page_id))
    |> Enum.reduce_while({:ok, 0}, fn attachment, {:ok, count} ->
      case upload_attachment(real_id, attachment) do
        :exists -> {:cont, {:ok, count}}
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upload_attachment(real_id, attachment) do
    if attachment_present?(real_id, attachment.filename) do
      :exists
    else
      HttpSource.upload_attachment(
        real_id,
        attachment.filename,
        attachment.media_type,
        attachment.content
      )
    end
  end

  defp attachment_present?(real_id, filename) do
    path =
      "/content/#{real_id}/child/attachment?filename=#{URI.encode_www_form(filename)}"

    case HttpSource.json(:get, path) do
      {:ok, %{"results" => [_ | _]}} -> true
      _ -> false
    end
  end

  defp add_comments(real_id, demo_page_id) do
    existing = existing_comment_bodies(real_id)

    DemoContent.comments()
    |> Enum.filter(&(&1.page_id == demo_page_id))
    |> Enum.sort_by(&(&1.parent_id != nil))
    |> Enum.reduce_while({:ok, 0, %{}}, fn comment, {:ok, count, created} ->
      if MapSet.member?(existing, comment.body_export) do
        {:cont, {:ok, count, created}}
      else
        case create_comment(real_id, comment, Map.get(created, comment.parent_id)) do
          {:ok, id} -> {:cont, {:ok, count + 1, Map.put(created, comment.id, id)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
    |> case do
      {:ok, count, _created} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # A comment is already mirrored when one with the same body exists; the body is
  # the demo's own HTML, which nobody else writes.
  defp existing_comment_bodies(real_id) do
    path = "/content/#{real_id}/child/comment?expand=body.storage&limit=100"

    case HttpSource.json(:get, path) do
      {:ok, %{"results" => results}} ->
        MapSet.new(for result <- results, do: get_in(result, ["body", "storage", "value"]))

      _ ->
        MapSet.new()
    end
  end

  defp create_comment(real_id, comment, parent_id) do
    body = %{
      type: "comment",
      container: %{id: to_string(real_id), type: "page"},
      body: %{storage: %{value: comment.body_export, representation: "storage"}}
    }

    body = if parent_id, do: Map.put(body, :ancestors, [%{id: to_string(parent_id)}]), else: body

    # Cloud rejects `POST /content/{id}/child/comment` (405); a comment is
    # created like any other content, with the page as its container.
    case HttpSource.json(:post, "/content", body) do
      {:ok, created} -> {:ok, created["id"]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_pages(space_key) do
    path = "/content?spaceKey=#{space_key}&type=page&limit=500&expand=metadata.labels"

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
