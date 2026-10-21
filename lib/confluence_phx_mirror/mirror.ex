defmodule ConfluencePhxMirror.Mirror do
  @moduledoc """
  Read/write access to mirrored Confluence content.

  Reads serve the web UI and the API; writes are used only by the sync
  pipeline. Queries always ignore pages that were deleted in Confluence, and
  always preload the space, because every page URL depends on it.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Mirror.{Attachment, Comment, Label, Link, Page, Space}
  alias ConfluencePhxMirror.Repo

  # ---------------------------------------------------------------------------
  # Spaces
  # ---------------------------------------------------------------------------

  def list_spaces do
    Repo.all(from s in Space, order_by: [asc: s.name])
  end

  def get_space_by_key(key) when is_binary(key) do
    Repo.get_by(Space, key: String.upcase(key))
  end

  def find_space(key) do
    case get_space_by_key(key) do
      nil -> {:error, :not_found}
      space -> {:ok, space}
    end
  end

  def get_space!(key) do
    get_space_by_key(key) || raise Ecto.NoResultsError, queryable: Space
  end

  def upsert_space(attrs) do
    space = Repo.get_by(Space, key: attrs.key) || %Space{}
    space |> Space.changeset(attrs) |> Repo.insert_or_update()
  end

  @doc "Spaces with their page counts, for the home page and admin dashboard."
  def spaces_with_counts do
    from(s in Space,
      left_join: p in assoc(s, :pages),
      where: is_nil(p.deleted_at),
      group_by: s.id,
      order_by: [asc: s.name],
      select: {s, count(p.id)}
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Pages
  # ---------------------------------------------------------------------------

  def list_pages(space_id, opts \\ []) do
    include_archived? = Keyword.get(opts, :include_archived, true)

    from(p in Page,
      where: p.space_id == ^space_id and is_nil(p.deleted_at),
      order_by: [asc: p.title]
    )
    |> maybe_exclude_archived(include_archived?)
    |> Repo.all()
  end

  defp maybe_exclude_archived(query, true), do: query
  defp maybe_exclude_archived(query, false), do: where(query, [p], p.status != "archived")

  def get_page!(confluence_id) do
    Repo.one!(
      from p in Page,
        where: p.confluence_id == ^confluence_id and is_nil(p.deleted_at),
        preload: [:space]
    )
  end

  def find_page(confluence_id) do
    case Repo.one(
           from p in Page,
             where: p.confluence_id == ^confluence_id and is_nil(p.deleted_at),
             preload: [:space]
         ) do
      nil -> {:error, :not_found}
      page -> {:ok, page}
    end
  end

  @doc "Finds a page by space key and Confluence id."
  def find_page_by_path(space_key, confluence_id) do
    with %Space{} = space <- get_space_by_key(space_key) do
      from(p in Page,
        where:
          p.space_id == ^space.id and p.confluence_id == ^confluence_id and is_nil(p.deleted_at),
        preload: [:space]
      )
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        page -> {:ok, page}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def upsert_page(space, attrs) do
    page = Repo.get_by(Page, confluence_id: attrs.confluence_id) || %Page{}

    page
    |> Page.changeset(Map.put(attrs, :space_id, space.id))
    |> Repo.insert_or_update()
  end

  @doc "Stores the rendered HTML and the derived search text."
  def update_rendered(page, attrs) do
    page
    |> Ecto.Changeset.change(attrs)
    |> Repo.update()
  end

  @doc "Replaces the page's label set and keeps the denormalised array in sync."
  def replace_labels(page, label_names) do
    names =
      label_names
      |> Enum.map(&Label.normalise/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    Repo.transaction(fn ->
      from(pl in "page_labels", where: pl.page_id == ^page.id) |> Repo.delete_all()

      Enum.each(names, fn name ->
        label =
          %Label{}
          |> Label.changeset(%{name: name})
          |> Repo.insert(on_conflict: :nothing, conflict_target: :name)
          |> case do
            {:ok, %Label{id: nil}} -> Repo.get_by!(Label, name: name)
            {:ok, %Label{} = label} -> label
          end

        Repo.insert_all("page_labels", [%{page_id: page.id, label_id: label.id}],
          on_conflict: :nothing,
          conflict_target: [:page_id, :label_id]
        )
      end)

      page
      |> Ecto.Changeset.change(labels: names)
      |> Repo.update!()
    end)
  end

  @doc "Replaces the outgoing links of a page and resolves targets already in the mirror."
  def replace_links(page, links) do
    index = page_index()

    rows =
      links
      |> Enum.uniq_by(&{&1.href, &1.kind})
      |> Enum.map(fn link ->
        target = index[link.target_confluence_id]

        %{
          source_page_id: page.id,
          target_page_id: target && target.db_id,
          target_confluence_id: link.target_confluence_id,
          href: link.href,
          kind: link.kind,
          label: link.label,
          inserted_at: now(),
          updated_at: now()
        }
      end)

    Repo.transaction(fn ->
      from(l in Link, where: l.source_page_id == ^page.id) |> Repo.delete_all()

      if rows != [] do
        Repo.insert_all(Link, rows)
      end

      :ok
    end)
  end

  @doc """
  Points every page at its parent's local id once all pages of a space exist.

  Confluence only gives us parent *Confluence ids*; the tree in Postgres uses
  local ids, so this runs after a snapshot upsert.
  """
  def resolve_parents(space) do
    pages =
      Repo.all(from p in Page, where: p.space_id == ^space.id and is_nil(p.deleted_at))

    by_confluence_id = Map.new(pages, &{&1.confluence_id, &1})

    Enum.each(pages, fn page ->
      parent = page.ancestors |> List.last() |> then(&by_confluence_id[&1])

      parent_id =
        case parent do
          nil -> nil
          %Page{id: id} -> id
        end

      if parent_id != page.parent_id do
        page |> Ecto.Changeset.change(parent_id: parent_id) |> Repo.update!()
      end
    end)

    :ok
  end

  @doc """
  Marks pages of `space` that Confluence no longer returns as deleted.

  Rows are kept for the audit trail; queries filter on `deleted_at`.
  """
  def mark_missing_deleted(space, seen_confluence_ids) do
    query =
      from p in Page,
        where:
          p.space_id == ^space.id and is_nil(p.deleted_at) and
            p.confluence_id not in ^Enum.to_list(seen_confluence_ids)

    {count, _} = Repo.update_all(query, set: [deleted_at: now(), updated_at: now()])
    count
  end

  def mark_deleted(confluence_id) do
    case Repo.get_by(Page, confluence_id: confluence_id) do
      nil ->
        {:error, :not_found}

      page ->
        page |> Ecto.Changeset.change(deleted_at: now()) |> Repo.update()
    end
  end

  @doc """
  Map of `confluence_id => %{space_key, confluence_id, slug}` used by the
  renderer to resolve cross-links without N queries.
  """
  def page_index do
    from(p in Page,
      join: s in assoc(p, :space),
      where: is_nil(p.deleted_at),
      select: {p.confluence_id, p.id, s.key, p.slug}
    )
    |> Repo.all()
    |> Map.new(fn {confluence_id, db_id, space_key, slug} ->
      {confluence_id,
       %{db_id: db_id, space_key: space_key, confluence_id: confluence_id, slug: slug}}
    end)
  end

  # ---------------------------------------------------------------------------
  # Trees, navigation and backlinks
  # ---------------------------------------------------------------------------

  @doc "Root pages of a space."
  def root_pages(space_id) do
    from(p in Page,
      where: p.space_id == ^space_id and is_nil(p.parent_id) and is_nil(p.deleted_at),
      order_by: [asc: p.title]
    )
    |> Repo.all()
  end

  def children(page) do
    from(p in Page,
      where: p.parent_id == ^page.id and is_nil(p.deleted_at),
      order_by: [asc: p.title]
    )
    |> Repo.all()
  end

  @doc """
  The whole page tree of a space as nested `%{page: page, children: [...]}`.

  Built in one query; sibling order is alphabetical.
  """
  def tree(space_id) do
    pages = list_pages(space_id)

    children_by_parent = Enum.group_by(pages, & &1.parent_id)
    ids = MapSet.new(pages, & &1.id)

    roots =
      Enum.filter(pages, fn page ->
        is_nil(page.parent_id) or not MapSet.member?(ids, page.parent_id)
      end)

    build_tree(roots, children_by_parent)
  end

  defp build_tree(pages, children_by_parent) do
    Enum.map(pages, fn page ->
      %{page: page, children: build_tree(children_by_parent[page.id] || [], children_by_parent)}
    end)
  end

  @doc "Breadcrumb trail (space included) in Confluence order."
  def breadcrumbs(%Page{} = page) do
    ancestors =
      page.ancestors
      |> Enum.map(fn confluence_id ->
        Repo.one(
          from p in Page,
            where: p.confluence_id == ^confluence_id and is_nil(p.deleted_at),
            select: %{title: p.title, confluence_id: p.confluence_id, slug: p.slug},
            limit: 1
        )
      end)
      |> Enum.reject(&is_nil/1)

    [%{title: page.space.name, space_key: page.space.key, kind: :space}] ++
      Enum.map(ancestors, &Map.put(&1, :kind, :page))
  end

  def backlinks(%Page{id: id}) do
    from(p in Page,
      join: l in assoc(p, :outgoing_links),
      where: l.target_page_id == ^id and is_nil(p.deleted_at),
      distinct: true,
      order_by: [asc: p.title],
      preload: [:space]
    )
    |> Repo.all()
  end

  def outgoing_links(%Page{id: id}) do
    from(l in Link,
      where: l.source_page_id == ^id,
      order_by: [asc: l.inserted_at],
      preload: [:target_page]
    )
    |> Repo.all()
  end

  def attachments(%Page{id: id}) do
    from(a in Attachment, where: a.page_id == ^id, order_by: [asc: a.filename])
    |> Repo.all()
  end

  def get_attachment!(space_key, page_confluence_id, attachment_confluence_id, filename) do
    Repo.one!(
      from a in Attachment,
        join: p in assoc(a, :page),
        join: s in assoc(p, :space),
        where:
          s.key == ^String.upcase(space_key) and p.confluence_id == ^page_confluence_id and
            a.confluence_id == ^attachment_confluence_id and a.filename == ^filename and
            is_nil(p.deleted_at),
        preload: [page: :space]
    )
  end

  def find_attachment(confluence_id) do
    case Repo.one(
           from a in Attachment, where: a.confluence_id == ^confluence_id, preload: [page: :space]
         ) do
      nil -> {:error, :not_found}
      attachment -> {:ok, attachment}
    end
  end

  def comments(%Page{id: id}) do
    from(c in Comment, where: c.page_id == ^id, order_by: [asc: c.external_created_at])
    |> Repo.all()
  end

  def pages_for_label(name) do
    from(p in Page,
      join: l in assoc(p, :label_records),
      where: l.name == ^Label.normalise(name) and is_nil(p.deleted_at),
      order_by: [desc: p.external_updated_at],
      preload: [:space]
    )
    |> Repo.all()
  end

  @doc "Labels with page counts, used by the label browser."
  def list_labels do
    from(l in Label,
      join: p in assoc(l, :pages),
      where: is_nil(p.deleted_at),
      group_by: l.id,
      order_by: [asc: l.name],
      select: {l.name, count(p.id)}
    )
    |> Repo.all()
  end

  def recent_pages(limit \\ 10) do
    from(p in Page,
      where: is_nil(p.deleted_at),
      order_by: [desc: p.external_updated_at],
      limit: ^limit,
      preload: [:space]
    )
    |> Repo.all()
  end

  def count_pages(space_id) do
    Repo.one(
      from p in Page,
        where: p.space_id == ^space_id and is_nil(p.deleted_at),
        select: count(p.id)
    )
  end

  def stats do
    %{
      spaces: Repo.aggregate(Space, :count),
      pages: Repo.one(from p in Page, where: is_nil(p.deleted_at), select: count(p.id)),
      attachments: Repo.aggregate(Attachment, :count),
      comments: Repo.aggregate(Comment, :count),
      labels: Repo.aggregate(Label, :count)
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
