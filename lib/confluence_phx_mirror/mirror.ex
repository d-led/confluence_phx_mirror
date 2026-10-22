defmodule ConfluencePhxMirror.Mirror do
  @moduledoc """
  Read/write access to mirrored Confluence content.

  Reads serve the web UI and the API; writes are used only by the sync
  pipeline. Queries always ignore pages that were deleted in Confluence, and
  always preload the space, because every page URL depends on it.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Mirror.{
    Attachment,
    Comment,
    GroupMember,
    Label,
    Link,
    Page,
    PageProperty,
    Space
  }

  alias ConfluencePhxMirror.Mirror.{PageRestriction, SpacePermission}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.SyncRun

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

  @doc "A mirrored space by its local id (subscriptions and jobs point at it)."
  def find_space_by_id(id) when is_integer(id) do
    case Repo.get(Space, id) do
      nil -> {:error, :not_found}
      space -> {:ok, space}
    end
  end

  @doc """
  A page by its local id.

  Subscriptions and notifications point at `page.id`, not at Confluence's id —
  `find_page/1` looks up the mirrored identity and would answer no for a local
  id that happens to match another page's Confluence id.
  """
  def find_page_by_local_id(id) when is_integer(id) do
    case Repo.get(Page, id) do
      nil -> {:error, :not_found}
      page -> {:ok, page}
    end
  end

  def get_space!(key) do
    get_space_by_key(key) || raise Ecto.NoResultsError, queryable: Space
  end

  def upsert_space(attrs) do
    key = Space.normalise_key(attrs.key)
    space = Repo.get_by(Space, key: key) || %Space{}
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
  # Permissions
  # ---------------------------------------------------------------------------

  @doc "Subjects that may read a space; empty means the space is open."
  def space_permissions(space_id) do
    from(c in SpacePermission,
      where: c.space_id == ^space_id and c.operation == "read",
      select: %{subject_type: c.subject_type, subject_key: c.subject_key}
    )
    |> Repo.all()
  end

  @doc "Replaces what we know about who may read a space."
  def replace_space_permissions(%Space{} = space, permissions) do
    Repo.transaction(fn ->
      Repo.delete_all(from c in SpacePermission, where: c.space_id == ^space.id)
      insert_subjects(SpacePermission, :space_id, space.id, permissions)
    end)
  end

  @doc "Subjects that may read a page; empty means it is unrestricted."
  def page_restrictions(confluence_id) do
    from(r in PageRestriction,
      join: p in Page,
      on: p.id == r.page_id,
      where: p.confluence_id == ^confluence_id and r.operation == "read",
      select: %{subject_type: r.subject_type, subject_key: r.subject_key}
    )
    |> Repo.all()
  end

  @doc "Replaces what we know about who may read a page."
  def replace_page_restrictions(%Page{} = page, restrictions) do
    Repo.transaction(fn ->
      Repo.delete_all(from r in PageRestriction, where: r.page_id == ^page.id)
      insert_subjects(PageRestriction, :page_id, page.id, restrictions)
    end)
  end

  defp insert_subjects(schema, foreign_key, id, subjects) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      subjects
      |> Enum.map(fn subject ->
        %{
          foreign_key => id,
          operation: "read",
          subject_type: to_string(subject.subject_type),
          subject_key: subject.subject_key,
          inserted_at: now,
          updated_at: now
        }
      end)
      |> Enum.uniq_by(&{&1.operation, &1.subject_type, &1.subject_key})

    if rows == [], do: 0, else: Repo.insert_all(schema, rows)
  end

  # ---------------------------------------------------------------------------
  # Group membership
  # ---------------------------------------------------------------------------

  @doc """
  Groups the mirrored content refers to: the subjects of page restrictions and
  space permissions. These are the groups whose membership decides access, so
  these are the ones a sync has to keep current.

  Returns `{name, key}` pairs; the key is the case-insensitive match form.
  """
  def referenced_groups do
    from(r in PageRestriction, where: r.subject_type == "group", select: r.subject_key)
    |> union(^from(p in SpacePermission, where: p.subject_type == "group", select: p.subject_key))
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{&1, GroupMember.key(&1)})
    |> Enum.uniq_by(&elem(&1, 1))
  end

  @doc "Members Confluence reported for a group, ordered by display name."
  def group_members(group) do
    key = GroupMember.key(group)

    from(m in GroupMember,
      where: m.group_key == ^key,
      order_by: [asc: m.display_name, asc: m.subject_key]
    )
    |> Repo.all()
  end

  @doc "Every mirrored group with its member count, for the admin screen."
  def groups_with_counts do
    from(m in GroupMember,
      group_by: [m.group_key, m.group_name],
      order_by: [asc: m.group_key],
      select: {m.group_name, m.group_key, count(m.id)}
    )
    |> Repo.all()
  end

  @doc """
  Replaces what we know about one group's membership with what Confluence just
  said. A member who left the group disappears here, which is the point.
  """
  def replace_group_members(group_name, members) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    group_key = GroupMember.key(group_name)

    rows =
      members
      |> Enum.map(&member_row(&1, group_name, group_key, now))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.subject_key)

    Repo.transaction(fn ->
      Repo.delete_all(from m in GroupMember, where: m.group_key == ^group_key)

      if rows != [], do: Repo.insert_all(GroupMember, rows)
      length(rows)
    end)
  end

  defp member_row(member, group_name, group_key, now) do
    case GroupMember.subject_key(member) do
      nil ->
        nil

      subject_key ->
        %{
          group_name: group_name,
          group_key: group_key,
          subject_key: subject_key,
          email: Map.get(member, :email),
          account_id: Map.get(member, :account_id),
          display_name: Map.get(member, :display_name),
          inserted_at: now,
          updated_at: now
        }
    end
  end

  @doc """
  Whether any of `subject_keys` (a reader's e-mail and account id) belongs to
  one of `group_keys`. Group names are compared case-insensitively.
  """
  def member_of_any_group?(subject_keys, group_keys) do
    keys = Enum.map(group_keys, &GroupMember.key/1)
    subjects = Enum.reject(subject_keys, &is_nil/1)

    from(m in GroupMember,
      where: m.group_key in ^keys and m.subject_key in ^subjects,
      limit: 1,
      select: 1
    )
    |> Repo.exists?()
  end

  @doc "Whether a reader belongs to one group."
  def member_of_group?(subject_keys, group_key) do
    member_of_any_group?(subject_keys, [group_key])
  end

  @doc "Names of the mirrored groups a reader belongs to, as Confluence spells them."
  def groups_of(subject_keys) do
    subjects = Enum.reject(subject_keys, &is_nil/1)

    from(m in GroupMember,
      where: m.subject_key in ^subjects,
      order_by: [asc: m.group_name],
      select: m.group_name
    )
    |> Repo.all()
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # Pages
  # ---------------------------------------------------------------------------

  def list_pages(space_id, opts \\ []) do
    include_archived? = Keyword.get(opts, :include_archived, true)

    from(p in Page,
      where: p.space_id == ^space_id and is_nil(p.deleted_at),
      order_by: [asc: p.title],
      preload: [:space]
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
    case get_space_by_key(space_key) do
      %Space{} = space ->
        from(p in Page,
          where:
            p.space_id == ^space.id and p.confluence_id == ^confluence_id and
              is_nil(p.deleted_at),
          preload: [:space]
        )
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          page -> {:ok, page}
        end

      nil ->
        {:error, :not_found}
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

  Rows are kept for the audit log; queries filter on `deleted_at`.
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
      order_by: [asc: p.title],
      preload: [:space]
    )
    |> Repo.all()
  end

  def children(page) do
    from(p in Page,
      where: p.parent_id == ^page.id and is_nil(p.deleted_at),
      order_by: [asc: p.title],
      preload: [:space]
    )
    |> Repo.all()
  end

  @doc """
  The whole page tree of a space as nested `%{page: page, children: [...]}`.

  Built in one query; sibling order is alphabetical. Confluence keeps blog posts
  out of the page tree and hides archived pages from navigation, so the tree
  does the same — both remain reachable through their catalogs.
  """
  def tree(space_id) do
    # Only what the sidebar draws. Selecting whole rows pulled `body_storage` and
    # `body_export` — every page's full content — and preloaded each page's
    # space, to render a list of titles and links.
    pages =
      from(p in Page,
        where: p.space_id == ^space_id and is_nil(p.deleted_at),
        where: p.status != "archived",
        order_by: [asc: p.title],
        select: %{
          id: p.id,
          space_id: p.space_id,
          parent_id: p.parent_id,
          title: p.title,
          type: p.type,
          slug: p.slug,
          confluence_id: p.confluence_id
        }
      )
      |> Repo.all()
      |> Enum.reject(&(&1.type == "blogpost"))

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
      page
      |> ancestor_pages()
      |> Enum.map(fn ancestor ->
        %{title: ancestor.title, confluence_id: ancestor.confluence_id, slug: ancestor.slug}
      end)

    [
      %{
        title: page.space.name,
        space_key: page.space.key,
        homepage_confluence_id: page.space.homepage_confluence_id,
        kind: :space
      }
    ] ++ Enum.map(ancestors, &Map.put(&1, :kind, :page))
  end

  @doc "Ancestor pages in Confluence order (root first)."
  def ancestor_pages(%Page{ancestors: ids}) when is_list(ids) do
    pages =
      Repo.all(
        from p in Page,
          where: p.confluence_id in ^ids and is_nil(p.deleted_at),
          preload: [:space]
      )

    by_id = Map.new(pages, &{&1.confluence_id, &1})
    Enum.flat_map(ids, fn id -> List.wrap(by_id[id]) end)
  end

  def ancestor_pages(_page), do: []

  @doc "Most recent sync run (any status)."
  def last_sync_run do
    Repo.one(from r in SyncRun, order_by: [desc: r.started_at], limit: 1)
  end

  @doc "Most recent sync run that changed the mirror."
  def last_successful_sync_run do
    Repo.one(
      from r in SyncRun,
        where: r.status in ["succeeded", "partial"],
        order_by: [desc: r.finished_at],
        limit: 1
    )
  end

  def get_space_home(%Space{homepage_confluence_id: nil}), do: nil

  def get_space_home(%Space{homepage_confluence_id: id}) do
    case find_page(id) do
      {:ok, page} -> page
      _ -> nil
    end
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

  def recent_pages(limit \\ 10) do
    from(p in Page,
      where: is_nil(p.deleted_at),
      order_by: [desc: p.external_updated_at],
      limit: ^limit,
      preload: [:space]
    )
    |> Repo.all()
  end

  def recent_pages_for_space(%Space{id: space_id}, limit) do
    from(p in Page,
      where: p.space_id == ^space_id and is_nil(p.deleted_at),
      order_by: [desc: p.external_updated_at],
      limit: ^limit,
      preload: [:space]
    )
    |> Repo.all()
  end

  @doc "Every mirrored page, newest first (API listings)."
  def list_all_pages do
    from(p in Page,
      where: is_nil(p.deleted_at),
      order_by: [desc: p.external_updated_at],
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

  # ---------------------------------------------------------------------------
  # Catalogs (the Confluence-style browse views)
  # ---------------------------------------------------------------------------

  # The catalog queries themselves live in `ConfluencePhxMirror.Catalog`: they
  # are filtered and paged per reader, which is a different job from the point
  # lookups in this module.

  @doc """
  Content of one space, archived pages included.

  Options: `:type` (`"page"`, `"blogpost"` or `nil` for both), `:sort`
  (`:title` or `:updated`) and `:limit`.
  """
  def pages_in_space(space_id, opts \\ []) do
    sort = Keyword.get(opts, :sort, :title)
    limit = Keyword.get(opts, :limit)

    from(p in Page,
      where: p.space_id == ^space_id and is_nil(p.deleted_at),
      order_by: ^order_by(sort),
      preload: [:space]
    )
    |> where_type(Keyword.get(opts, :type))
    |> limit_rows(limit)
    |> Repo.all()
  end

  @doc "Blog posts of a space (or of the whole mirror), newest first."
  def blog_posts(space_id \\ nil, limit \\ 20) do
    from(p in Page,
      where: p.type == "blogpost" and is_nil(p.deleted_at),
      order_by: [desc: p.external_updated_at],
      limit: ^limit,
      preload: [:space]
    )
    |> where_space(space_id)
    |> Repo.all()
  end

  @doc "Attachments of every page in a space, for the space attachment list."
  def attachments_in_space(space_id) do
    from(a in Attachment,
      join: p in assoc(a, :page),
      where: p.space_id == ^space_id and is_nil(p.deleted_at),
      order_by: [asc: a.filename],
      preload: [page: :space]
    )
    |> Repo.all()
  end

  @doc "Labels used in one space, with their page counts."
  def labels_in_space(space_id) do
    from(l in Label,
      join: p in assoc(l, :pages),
      where: p.space_id == ^space_id and is_nil(p.deleted_at),
      group_by: l.id,
      order_by: [asc: l.name],
      select: {l.name, count(p.id)}
    )
    |> Repo.all()
  end

  @doc """
  People who authored mirrored content, with page counts.

  Confluence's people directory is served from mirrored bylines rather than a
  separate user sync: the mirror never invents accounts it has not seen.
  """
  def authors do
    from(p in Page,
      where: is_nil(p.deleted_at) and not is_nil(p.author_name),
      group_by: [p.author_name, p.author_account_id],
      order_by: [asc: p.author_name],
      select: %{
        name: p.author_name,
        account_id: p.author_account_id,
        pages: count(p.id),
        updated_at: max(p.external_updated_at)
      }
    )
    |> Repo.all()
  end

  @doc "All content authored by one Confluence account."
  def pages_by_author(account_id) when is_binary(account_id) do
    from(p in Page,
      where: p.author_account_id == ^account_id and is_nil(p.deleted_at),
      order_by: [desc: p.external_updated_at],
      preload: [:space]
    )
    |> Repo.all()
  end

  @doc "Looks an author up by Confluence account id."
  def find_author(account_id), do: Enum.find(authors(), &(&1.account_id == account_id))

  # ---------------------------------------------------------------------------
  # Dynamic content (macros Confluence resolves in the browser)
  # ---------------------------------------------------------------------------

  @doc """
  Pages carrying all (`:all`, the default) or any (`:any`) of `labels`.

  This is the mirror's own `content-by-label` resolver; the array operators are
  backed by GIN indexes, so it never walks the page table.
  """
  def pages_for_labels(labels, opts \\ []) do
    labels = labels |> Enum.map(&Label.normalise/1) |> Enum.reject(&(&1 == ""))

    if labels == [] do
      []
    else
      limit = Keyword.get(opts, :limit, 10)

      from(p in Page,
        where: is_nil(p.deleted_at),
        order_by: [desc: p.external_updated_at],
        limit: ^limit,
        preload: [:space]
      )
      |> where_labels(labels, Keyword.get(opts, :match, :all))
      |> where_space(Keyword.get(opts, :space_id))
      |> Repo.all()
    end
  end

  defp where_labels(query, labels, :any),
    do: where(query, [p], fragment("? && ?", p.labels, ^labels))

  defp where_labels(query, labels, _all),
    do: where(query, [p], fragment("? @> ?", p.labels, ^labels))

  @doc "Replaces the page's extracted `pageproperties` rows."
  def replace_properties(%Page{id: page_id}, properties) do
    Repo.transaction(fn ->
      Repo.delete_all(from p in PageProperty, where: p.page_id == ^page_id)

      Enum.each(properties, fn property ->
        Repo.insert!(%PageProperty{
          page_id: page_id,
          key: property.key,
          value: property.value
        })
      end)
    end)

    {:ok, properties}
  end

  @doc "Property rows of one page, ordered by key."
  def properties(%Page{id: page_id}) do
    from(p in PageProperty, where: p.page_id == ^page_id, order_by: [asc: p.key])
    |> Repo.all()
  end

  @doc """
  Data for a page-properties report: the pages of a space that declare
  properties, with the requested columns.

  Returns `%{columns: [String.t()], rows: [%{page: Page.t(), values: map()}]}`.
  Columns default to the keys actually present, alphabetically, capped at six.
  """
  def property_report(space_id, columns \\ []) do
    pages =
      from(p in Page,
        join: property in assoc(p, :properties),
        where: p.space_id == ^space_id and is_nil(p.deleted_at),
        distinct: true,
        order_by: [asc: p.title],
        preload: [:space, :properties]
      )
      |> Repo.all()

    columns =
      case columns do
        [] ->
          pages
          |> Enum.flat_map(fn page -> Enum.map(page.properties, & &1.key) end)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.take(6)

        columns ->
          columns
      end

    %{
      columns: columns,
      rows:
        Enum.map(pages, fn page ->
          %{page: page, values: Map.new(page.properties, &{&1.key, &1.value})}
        end)
    }
  end

  @doc """
  Pages whose rendered body contains a dynamic macro marker.

  Re-rendering these after content changes is how a static mirror keeps
  label-driven listings and property reports current without a browser.
  """
  def pages_with_dynamic_content(limit \\ 200) do
    from(p in Page,
      where: is_nil(p.deleted_at) and like(p.body_export, "%mirror-macro%"),
      order_by: [desc: p.external_updated_at],
      limit: ^limit,
      preload: [:space]
    )
    |> Repo.all()
  end

  defp where_type(query, nil), do: query
  defp where_type(query, type), do: where(query, [p], p.type == ^type)

  defp where_space(query, nil), do: query
  defp where_space(query, space_id), do: where(query, [p], p.space_id == ^space_id)

  defp order_by(:updated), do: [desc: :external_updated_at]
  defp order_by(_title), do: [asc: :title]

  defp limit_rows(query, nil), do: query
  defp limit_rows(query, limit), do: limit(query, ^limit)

  def stats do
    # One statement: five aggregates, five subqueries. Asking the repo five
    # times cost five round trips on every home page view.
    Repo.one(
      from(s in Space,
        select: %{
          spaces: count(s.id),
          pages: fragment("(SELECT count(*) FROM pages WHERE deleted_at IS NULL)"),
          attachments: fragment("(SELECT count(*) FROM attachments)"),
          comments: fragment("(SELECT count(*) FROM comments)"),
          labels: fragment("(SELECT count(*) FROM labels)")
        }
      )
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
