defmodule ConfluencePhxMirror.Mirror do
  @moduledoc """
  Read/write access to mirrored Confluence content.

  Reads serve the web UI and the API; writes are used only by the sync
  pipeline. Queries always ignore pages that were deleted in Confluence, and
  preload the space where the caller has none — a page URL depends on it, so a
  list that crosses spaces carries its space, and a screen that already holds
  the space does not ask again.

  Totals that need a scan of the content (see `Mirror.Counters`) are computed
  once per content version, not once per request.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Mirror.{
    Attachment,
    Comment,
    Counters,
    GroupMember,
    Label,
    Link,
    Page,
    PageProperty,
    Space
  }

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror.{PageRestriction, SpacePermission}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.SyncRun

  # ---------------------------------------------------------------------------
  # Spaces
  # ---------------------------------------------------------------------------

  @doc """
  Mirrored spaces by name.

  Options: `:limit` — the search screen's space menus take a window and leave
  the directory to `/spaces`; `:query` — a case-insensitive match on the name or
  the key, run here rather than in a browser, so a site with hundreds of spaces
  sends forty rows and not the whole directory.
  """
  def list_spaces(opts \\ []) do
    from(s in Space,
      where: is_nil(s.deleted_at),
      order_by: [asc: s.name],
      limit: ^Keyword.get(opts, :limit)
    )
    |> named_like(Keyword.get(opts, :query, ""))
    |> Repo.all()
  end

  @doc """
  Narrows a `Space` query to the spaces whose name or key matches `term`.

  Public because the shell's space switcher runs the same search under the
  reader's permissions: the menu and the directory must agree on what "LOAD01"
  finds.
  """
  def named_like(queryable, blank) when blank in [nil, ""], do: queryable

  def named_like(queryable, term) do
    pattern = "%" <> String.replace(term, ["\\", "%", "_"], &("\\" <> &1)) <> "%"

    where(queryable, [s], ilike(s.name, ^pattern) or ilike(s.key, ^pattern))
  end

  def get_space_by_key(key) when is_binary(key) do
    key = String.upcase(key)

    Repo.one(from s in Space, where: s.key == ^key and is_nil(s.deleted_at))
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

    space
    |> Space.changeset(attrs)
    |> revive(space)
    |> Repo.insert_or_update()
  end

  @doc """
  Spaces with their page counts, for the home page and admin dashboard.

  Counting every space's pages is a pass over the pages table, so the answer is
  remembered until the content moves (see `Mirror.Counters`).
  """
  def spaces_with_counts do
    Counters.fetch(:spaces_with_counts, fn ->
      from(s in Space,
        left_join: p in assoc(s, :pages),
        where: is_nil(s.deleted_at) and is_nil(p.deleted_at),
        group_by: s.id,
        order_by: [asc: s.name],
        select: {s, count(p.id)}
      )
      |> Repo.all()
    end)
  end

  # ---------------------------------------------------------------------------
  # Permissions
  # ---------------------------------------------------------------------------

  @doc """
  Whether anything in the mirror is restricted.

  Two existence checks, remembered until the content moves. They answer the
  question a screen asks before it decides whether a per-reader query is needed
  at all: with no space permissions and no page restrictions, every reader sees
  every page.
  """
  def any_permissions? do
    Counters.fetch(:permissions?, fn ->
      Repo.exists?(from(c in SpacePermission, select: 1, limit: 1)) or
        Repo.exists?(from(r in PageRestriction, select: 1, limit: 1))
    end)
  end

  @doc """
  Whether a personal space is mirrored.

  A personal space belongs to one person and is invisible to everybody else even
  though it usually carries no permissions at all, so "nothing is restricted
  here" is not the same question as "everybody sees the same content".
  """
  def any_personal_spaces? do
    Counters.fetch(:personal_spaces?, fn ->
      Repo.exists?(
        from(s in Space,
          where: s.type == "personal" and is_nil(s.deleted_at),
          select: 1,
          limit: 1
        )
      )
    end)
  end

  @doc "Subjects that may read a space; empty means the space is open."
  def space_permissions(space_id) do
    from(c in SpacePermission,
      where: c.space_id == ^space_id and c.operation == "read",
      select: %{subject_type: c.subject_type, subject_key: c.subject_key}
    )
    |> Repo.all()
  end

  @doc """
  Who may read a space, as the last sync read it — what the admin's space page
  shows: groups, people, and whether anonymous readers are included.

  A user subject is stored under every identifier Confluence named it by (the
  account id and, when shared, the e-mail), so people are answered once per
  account where the mirror knows one.
  """
  def space_grants(space_id) do
    subjects = space_permissions(space_id)

    %{
      groups:
        subjects
        |> Enum.filter(&(&1.subject_type == "group"))
        |> Enum.map(& &1.subject_key)
        |> Enum.uniq()
        |> Enum.sort(),
      users: user_grants(subjects),
      anonymous: Enum.any?(subjects, &(&1.subject_type == "anonymous")),
      synced?: subjects != []
    }
  end

  defp user_grants(subjects) do
    keys = for %{subject_type: "user", subject_key: key} <- subjects, do: key

    accounts =
      from(u in User,
        where: u.confluence_account_id in ^keys or fragment("lower(?)", u.email) in ^keys,
        select: {u.confluence_account_id, u.email, u.display_name}
      )
      |> Repo.all()

    keys
    |> Enum.uniq()
    |> Enum.map(fn key ->
      case Enum.find(accounts, fn {id, email, _name} -> key in [id, email] end) do
        {_id, email, name} -> %{key: key, label: name || email, account?: true}
        nil -> %{key: key, label: key, account?: false}
      end
    end)
    |> Enum.uniq_by(& &1.key)
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

  This is the group-first direction: "who is in this group". Confluence Cloud
  no longer answers it, so live sites learn membership the other way round —
  see `replace_subject_groups/2`.
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
  Replaces what we know about the groups one account belongs to.

  This is the person-first direction: "which groups is this account in", the
  only one Confluence Cloud still answers. Called once per identity the mirror
  knows, it keeps the same `group_members` rows the group-first direction
  writes, so access questions and the admin screen read them the same way.
  """
  def replace_subject_groups(identity, group_names) when is_map(identity) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    subject_key = GroupMember.subject_key(identity)

    rows =
      group_names
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&GroupMember.key/1)
      |> Enum.map(&subject_row(&1, identity, subject_key, now))

    case subject_key do
      nil ->
        {:ok, 0}

      key ->
        Repo.transaction(fn ->
          delete_subject_memberships(key, Map.get(identity, :account_id))
          if rows != [], do: Repo.insert_all(GroupMember, rows)
          length(rows)
        end)
    end
  end

  defp subject_row(group_name, identity, subject_key, now) do
    %{
      group_name: group_name,
      group_key: GroupMember.key(group_name),
      subject_key: subject_key,
      email: Map.get(identity, :email),
      account_id: Map.get(identity, :account_id),
      display_name: Map.get(identity, :display_name),
      inserted_at: now,
      updated_at: now
    }
  end

  # An account can be known by its e-mail on one run and by its account id on
  # another; both key its rows, so both are cleared.
  defp delete_subject_memberships(subject_key, nil) do
    Repo.delete_all(from m in GroupMember, where: m.subject_key == ^subject_key)
  end

  defp delete_subject_memberships(subject_key, account_id) do
    Repo.delete_all(
      from m in GroupMember,
        where: m.subject_key == ^subject_key or m.account_id == ^account_id
    )
  end

  @doc """
  The Confluence identities the mirrored content names: every page and comment
  author.

  This is the only user directory a Confluence Cloud mirror can have. The site
  does not list its users, and it stopped answering "who is in this group"; what
  it does answer is which groups one account belongs to, and what the content
  itself says is who wrote it.
  """
  def known_identities do
    from(p in Page,
      where: not is_nil(p.author_account_id),
      distinct: true,
      select: {p.author_account_id, p.author_name}
    )
    |> union_all(
      ^from(c in Comment,
        where: not is_nil(c.author_account_id),
        distinct: true,
        select: {c.author_account_id, c.author_name}
      )
    )
    |> Repo.all()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {account_id, display_name} ->
      %{account_id: account_id, display_name: display_name}
    end)
  end

  @doc """
  The people Confluence's content names, each with the groups the last sync read
  — what the admin screen shows as the site's side of the story.

  A site can name a hundred thousand people, and the screen must not try to draw
  them all: `:limit` and `:offset` page the answer in the database, and the
  groups are read for that page only. Without a limit the whole list comes back,
  which is what tests and small sites want.
  """
  def people(opts \\ []) do
    page = identities_page(opts)
    groups = groups_by_subject(Enum.map(page, & &1.account_id))

    Enum.map(page, &Map.put(&1, :groups, Map.get(groups, &1.account_id, [])))
  end

  @doc "How many people the content names, for the screen's \"of N\"."
  def count_people do
    identities_query()
    |> subquery()
    |> select([i], count())
    |> Repo.one()
  end

  defp identities_page(opts) do
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    identities_query()
    |> order_by([i], asc: coalesce(max(i.display_name), i.account_id))
    |> limit_if(limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp limit_if(query, nil), do: query
  defp limit_if(query, limit), do: limit(query, ^limit)

  # One row per person, however often the content names them.
  defp identities_query do
    from(p in Page,
      where: not is_nil(p.author_account_id),
      select: %{account_id: p.author_account_id, display_name: p.author_name}
    )
    |> union_all(
      ^from(c in Comment,
        where: not is_nil(c.author_account_id),
        select: %{account_id: c.author_account_id, display_name: c.author_name}
      )
    )
    |> subquery()
    |> group_by([i], i.account_id)
    |> select([i], %{account_id: i.account_id, display_name: max(i.display_name)})
  end

  defp groups_by_subject(account_ids) do
    from(m in GroupMember,
      where: m.account_id in ^account_ids,
      select: {m.subject_key, m.group_name}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  The group names the last sync actually wrote a member for.

  Not the same list as the configured admin groups: a site's group is called
  what the site calls it (`confluence-admins-dled`, not `confluence-admins`), so
  an empty admin panel on a synced mirror is a name that does not match, not a
  sync that never ran. This is the list that tells them apart.
  """
  def synced_group_names do
    from(m in GroupMember, distinct: true, select: m.group_name, order_by: m.group_name)
    |> Repo.all()
  end

  @doc """
  Whether any of `subject_keys` (a reader's e-mail and account id) belongs to
  one of `group_keys`. Group names are compared case-insensitively.

  Either list being empty is answered without asking the database: a
  deployment with no admin groups, and a reader with no identity, are both
  common, and this is called for every access question.
  """
  def member_of_any_group?(subject_keys, group_keys) do
    keys = Enum.map(group_keys, &GroupMember.key/1)
    subjects = Enum.reject(subject_keys, &is_nil/1)

    if keys == [] or subjects == [] do
      false
    else
      from(m in GroupMember,
        where: m.group_key in ^keys and m.subject_key in ^subjects,
        limit: 1,
        select: 1
      )
      |> Repo.exists?()
    end
  end

  @doc "Whether a reader belongs to one group."
  def member_of_group?(subject_keys, group_key) do
    member_of_any_group?(subject_keys, [group_key])
  end

  @doc """
  The Atlassian account ids the mirror knows: page authors and group members.

  This is the only list there is — Confluence Cloud has no API that enumerates
  a site's users — and it is what the sync asks about when it wants to know who
  the site has switched off.
  """
  @spec account_ids() :: [String.t()]
  def account_ids do
    from(p in Page,
      where: not is_nil(p.author_account_id),
      distinct: true,
      select: p.author_account_id
    )
    |> Repo.all()
  end

  @doc "Account ids Confluence reported for group members."
  @spec member_account_ids() :: [String.t()]
  def member_account_ids do
    from(m in GroupMember,
      where: not is_nil(m.account_id),
      distinct: true,
      select: m.account_id
    )
    |> Repo.all()
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

  @doc """
  Whether the sync has ever seen this identity on the mirrored site.
  There is no user directory to consult — Confluence Cloud does not list a
  site's users through the API — so "a user of the site" means "the mirror has
  evidence of this person": a member of a group the content mentions, a user
  named in a space permission or a page restriction. Mirror administrators are
  a separate question, answered by `ConfluencePhxMirror.Accounts.Admins`.

  Identities are matched case-insensitively, like the permission checks do.
  """
  @spec identity_known?([String.t() | nil]) :: boolean()
  def identity_known?(subject_keys) do
    subjects = subject_keys |> Enum.reject(&is_nil/1) |> Enum.map(&String.downcase/1)

    if subjects == [] do
      false
    else
      member? =
        from(m in GroupMember,
          where: fragment("lower(?)", m.subject_key) in ^subjects,
          limit: 1,
          select: 1
        )

      space_named? =
        from(sp in SpacePermission,
          where:
            sp.subject_type == "user" and
              fragment("lower(?)", sp.subject_key) in ^subjects,
          limit: 1,
          select: 1
        )

      page_named? =
        from(r in PageRestriction,
          where: r.subject_type == "user" and fragment("lower(?)", r.subject_key) in ^subjects,
          limit: 1,
          select: 1
        )

      Repo.exists?(member?) or Repo.exists?(space_named?) or Repo.exists?(page_named?)
    end
  end

  @doc """
  Whether the site lists these people in any of these groups.

  An identity provider in front of the mirror may assert group names; the one
  thing the mirror can check about that claim is its own membership mirror. A
  group the site has never shown is not evidence, and neither is a group the
  site lists with somebody else in it — which is why the person is looked up
  inside the group, not the group on its own.
  """
  @spec members_of_asserted_groups?([String.t()], [String.t() | nil]) :: boolean()
  def members_of_asserted_groups?(group_names, subject_keys) do
    groups = group_names |> Enum.reject(&(&1 in [nil, ""])) |> Enum.map(&GroupMember.key/1)
    subjects = subject_keys |> Enum.reject(&is_nil/1) |> Enum.map(&GroupMember.key/1)

    if groups == [] or subjects == [] do
      false
    else
      from(m in GroupMember,
        where:
          fragment("lower(?)", m.group_name) in ^groups and
            fragment("lower(?)", m.subject_key) in ^subjects,
        limit: 1,
        select: 1
      )
      |> Repo.exists?()
    end
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
    from(p in Page,
      join: s in assoc(p, :space),
      where:
        s.key == ^String.upcase(space_key) and p.confluence_id == ^confluence_id and
          is_nil(p.deleted_at),
      preload: [space: s]
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      page -> {:ok, page}
    end
  end

  def upsert_page(space, attrs) do
    page = Repo.get_by(Page, confluence_id: attrs.confluence_id) || %Page{}

    page
    |> Page.changeset(Map.put(attrs, :space_id, space.id))
    |> revive(page)
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
  Marks pages of `space` that Confluence no longer returns as deleted, and their
  comments with them.

  Rows are kept for the audit log and for an administrator to purge from the
  trash; queries filter on `deleted_at`.
  """
  def mark_missing_deleted(space, seen_confluence_ids) do
    now = now()

    ids =
      from(p in Page,
        where:
          p.space_id == ^space.id and is_nil(p.deleted_at) and
            p.confluence_id not in ^Enum.to_list(seen_confluence_ids),
        select: p.id
      )
      |> Repo.all()

    trash_pages(ids, now)
    length(ids)
  end

  def mark_deleted(confluence_id) do
    case Repo.get_by(Page, confluence_id: confluence_id) do
      nil ->
        {:error, :not_found}

      page ->
        now = now()
        page = page |> Ecto.Changeset.change(deleted_at: now) |> Repo.update!()
        trash_comments([page.id], now)
        {:ok, page}
    end
  end

  # ---------------------------------------------------------------------------
  # Trash
  # ---------------------------------------------------------------------------

  @doc """
  Trashes the mirrored spaces a snapshot no longer lists, with their pages and
  those pages' comments. Returns `{spaces, pages}`.

  The same rule as a deleted page: the space stops being readable here, but its
  rows stay until an administrator purges them (`ConfluencePhxMirror.Trash`).
  """
  def prune_missing_spaces(seen_keys) do
    keep = Enum.map(seen_keys, &Space.normalise_key/1)

    from(s in Space, where: is_nil(s.deleted_at) and s.key not in ^keep)
    |> Repo.all()
    |> Enum.map(&{&1, trash_space(&1)})
  end

  @doc "Trashes one space with its pages and their comments; returns how many pages."
  def trash_space(%Space{} = space) do
    now = now()

    ids =
      from(p in Page, where: p.space_id == ^space.id and is_nil(p.deleted_at), select: p.id)
      |> Repo.all()

    trash_pages(ids, now)

    from(s in Space, where: s.id == ^space.id and is_nil(s.deleted_at))
    |> Repo.update_all(set: [deleted_at: now, updated_at: now])

    length(ids)
  end

  @doc """
  Spaces in the trash, newest first, with the number of pages that go with each.
  """
  def trashed_spaces do
    from(s in Space,
      where: not is_nil(s.deleted_at),
      order_by: [desc: s.deleted_at],
      select: {s, fragment("(SELECT count(*) FROM pages p WHERE p.space_id = ?)", s.id)}
    )
    |> Repo.all()
  end

  @doc """
  Trashed pages and blog posts that did not go with a trashed space.

  Options: `:type` (`"page"` or `"blogpost"`) and `:limit`.
  """
  def trashed_pages(opts \\ []) do
    query =
      from(p in Page,
        join: s in assoc(p, :space),
        where: not is_nil(p.deleted_at) and is_nil(s.deleted_at),
        order_by: [desc: p.deleted_at, asc: p.title],
        limit: ^Keyword.get(opts, :limit),
        select: {p, s}
      )

    case Keyword.get(opts, :type) do
      nil -> query
      type -> where(query, [p, _s], p.type == ^type)
    end
    |> Repo.all()
  end

  @doc """
  Removes a trashed space for good: its pages, their comments and attachments,
  and every row that hangs off them (Postgres cascades), plus its icon.

  Returns the blob keys the caller must delete from the store. Refuses a space
  that is not in the trash, so a live space cannot be purged by mistake.
  """
  def purge_space(%Space{} = space) do
    case Repo.get(Space, space.id) do
      %Space{deleted_at: %DateTime{}} = trashed ->
        Repo.transaction(fn ->
          keys =
            from(a in Attachment,
              join: p in assoc(a, :page),
              where: p.space_id == ^trashed.id,
              select: a.blob_key
            )
            |> blob_keys()

          pages = Repo.aggregate(from(p in Page, where: p.space_id == ^trashed.id), :count)
          Repo.delete!(trashed)

          %{
            pages: pages,
            blob_keys: [trashed.icon_blob_key | keys] |> Enum.reject(&is_nil/1) |> Enum.uniq()
          }
        end)

      nil ->
        {:error, :not_found}

      _live ->
        {:error, :not_trashed}
    end
  end

  @doc """
  Removes a trashed page for good, with its comments, attachments and the rows
  that hang off it. Returns the blob keys the caller must delete.
  """
  def purge_page(%Page{} = page) do
    case Repo.get(Page, page.id) do
      %Page{deleted_at: %DateTime{}} = trashed ->
        Repo.transaction(fn ->
          keys =
            from(a in Attachment, where: a.page_id == ^trashed.id, select: a.blob_key)
            |> blob_keys()

          Repo.delete!(trashed)
          %{blob_keys: keys}
        end)

      nil ->
        {:error, :not_found}

      _live ->
        {:error, :not_trashed}
    end
  end

  defp blob_keys(query), do: query |> Repo.all() |> Enum.reject(&is_nil/1)

  # The counterpart of trashing: something that disappeared and came back — a
  # page restored from Confluence's trash, a space someone deleted by mistake —
  # is live again the moment a sync sees it. Nothing revives on its own.
  defp revive(changeset, %{deleted_at: nil}), do: changeset
  defp revive(changeset, _trashed), do: Ecto.Changeset.put_change(changeset, :deleted_at, nil)

  defp trash_pages([], _now), do: 0

  defp trash_pages(ids, now) do
    {pages, _} =
      from(p in Page, where: p.id in ^ids)
      |> Repo.update_all(set: [deleted_at: now, updated_at: now])

    trash_comments(ids, now)
    pages
  end

  defp trash_comments(page_ids, now) do
    {comments, _} =
      from(c in Comment, where: c.page_id in ^page_ids and is_nil(c.deleted_at))
      |> Repo.update_all(set: [deleted_at: now, updated_at: now])

    comments
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

  @doc """
  Root pages of a space, as the space overview draws them.

  No space preload and no bodies: the overview already holds the space, and a
  card needs a title, a link and an excerpt.

  Options: `:limit`. The overview shows a handful and links to the catalog; a
  space with three hundred root pages is not worth three hundred cards.
  """
  def root_pages(space_id, opts \\ []) do
    from(p in Page,
      as: :page,
      where: p.space_id == ^space_id and is_nil(p.parent_id) and is_nil(p.deleted_at),
      order_by: [asc: p.title],
      select: %{
        id: p.id,
        space_id: p.space_id,
        confluence_id: p.confluence_id,
        type: p.type,
        title: p.title,
        slug: p.slug,
        body_text: p.body_text,
        external_updated_at: p.external_updated_at
      }
    )
    |> limit_rows(Keyword.get(opts, :limit))
    |> filtered(opts)
    |> Repo.all()
  end

  @doc "The pages directly below `page`, by title; `:limit` takes a window."
  def children(page, opts \\ []) do
    from(p in Page,
      as: :page,
      where: p.parent_id == ^page.id and is_nil(p.deleted_at),
      order_by: [asc: p.title],
      limit: ^Keyword.get(opts, :limit),
      preload: [:space]
    )
    |> filtered(opts)
    |> Repo.all()
  end

  @doc """
  How many children a page has.

  A front page with five hundred children is normal in a big space, and a page
  that lists all of them is a page nobody scrolls. The count lets the page show
  a window and say how much is behind it.
  """
  def count_children(%Page{} = page, opts \\ []) do
    from(p in Page, as: :page, where: p.parent_id == ^page.id and is_nil(p.deleted_at))
    |> filtered(opts)
    |> Repo.aggregate(:count)
  end

  @doc """
  The part of a space's tree the sidebar draws around `page`.

  A page view used to load every page of its space to draw the sidebar: at a
  thousand pages that is a thousand links and half a megabyte of response that
  no reader asked for, and it grows with the space, not with the page. What a
  reader navigates with is the trail from the root to the current page, so that
  is what is read: every level of the trail with its siblings, and the current
  page's children, `:siblings` rows per level (fifteen by default) around the
  reader's position.

  `truncated?` says a level was cut short, so the sidebar can offer the space's
  catalog — where the whole space can be searched and paged — instead of
  pretending the list is complete.

  Without a page it returns the space's root pages, which is what the overview
  and the catalogs need to know about the reader's position (nothing).

  Sibling order is alphabetical, and Confluence's rule that blog posts stay out
  of the page tree and archived pages stay out of navigation is kept: both are
  reachable through their catalogs. One statement, whatever the size.

  Options:

    * `:siblings` — rows per level (default 15)
    * `:filter` — a function applied to the query before it runs, which is how
      `Authorization.branch/3` keeps pages the reader may not open out of the
      sidebar without a second statement
  """
  def branch_tree(space_id, page \\ nil, opts \\ [])

  def branch_tree(space_id, nil, opts) do
    {nodes, truncated?} =
      space_id
      |> roots_query()
      |> filtered(opts)
      |> Repo.all()
      |> expand([], [], sibling_window(opts))

    %{nodes: nodes, truncated?: truncated?}
  end

  def branch_tree(space_id, %Page{} = page, opts) do
    path = (page.ancestors || []) ++ [page.confluence_id]
    nodes = space_id |> level_rows(page) |> filtered(opts) |> Repo.all()
    by_parent = Enum.group_by(nodes, & &1.parent_id)

    {tree, truncated?} = expand(by_parent[nil] || [], by_parent, path, sibling_window(opts))

    %{nodes: tree, truncated?: truncated?}
  end

  defp filtered(query, opts), do: Keyword.get(opts, :filter, & &1).(query)

  defp sibling_window(opts), do: Keyword.get(opts, :siblings, 15)

  # Rows whose parent is the root, the parent of an ancestor, or the page
  # itself: exactly the levels of the trail, plus the page's own children.
  defp level_rows(space_id, page) do
    ancestor_ids = page.ancestors || []
    parents = from(a in Page, where: a.confluence_id in ^ancestor_ids, select: a.id)

    navigation_query(space_id)
    |> where(
      [p],
      is_nil(p.parent_id) or p.id == ^page.id or p.parent_id == ^page.id or
        p.parent_id in subquery(parents)
    )
  end

  defp roots_query(space_id) do
    navigation_query(space_id) |> where([p], is_nil(p.parent_id))
  end

  @doc """
  The rows one sidebar node expands to, in the same shape the tree draws.

  The sidebar ships only the trail to the page being read; expanding a node asks
  for that node's children, so a space with a thousand pages costs one request
  per branch a reader actually opens.
  """
  def tree_children(space_id, %Page{} = page, opts \\ []) do
    space_id
    |> navigation_query()
    |> where([p], p.parent_id == ^page.id)
    |> filtered(opts)
    |> Repo.all()
  end

  # Only what the sidebar draws: selecting whole rows pulled `body_storage` and
  # `body_export` — every page's full content — to render titles and links.
  # Aliased `:page` so `Authorization.restrict_pages/2` can narrow it in place.
  defp navigation_query(space_id) do
    child = from(c in Page, where: c.parent_id == parent_as(:page).id and is_nil(c.deleted_at))

    from(p in Page,
      as: :page,
      where: p.space_id == ^space_id and is_nil(p.deleted_at),
      where: p.status != "archived" and p.type != "blogpost",
      order_by: [asc: p.title],
      select: %{
        id: p.id,
        space_id: p.space_id,
        parent_id: p.parent_id,
        title: p.title,
        type: p.type,
        slug: p.slug,
        confluence_id: p.confluence_id,
        # Whether the sidebar draws a chevron: a node with nothing below it
        # should not offer to open.
        has_children: exists(child)
      }
    )
  end

  # `path` is the trail below this level; the level is centred on the node that
  # leads to the current page, and only that node has children to expand.
  defp expand(nodes, by_parent, path, limit) do
    {shown, cut?} = window(nodes, limit, Enum.find(nodes, &(&1.confluence_id in path)))

    {built, deeper?} =
      Enum.map_reduce(shown, false, fn node, deeper? ->
        {children, child_cut?} =
          if node.confluence_id in path do
            expand(by_parent[node.id] || [], by_parent, path, limit)
          else
            {[], false}
          end

        {%{page: node, children: children}, deeper? or child_cut?}
      end)

    {built, cut? or deeper?}
  end

  defp window(nodes, limit, on_path) do
    count = length(nodes)

    if count <= limit do
      {nodes, false}
    else
      target = on_path && on_path.id
      index = Enum.find_index(nodes, &(&1.id == target)) || 0
      start = (index - div(limit, 2)) |> max(0) |> min(count - limit)
      {Enum.slice(nodes, start, limit), true}
    end
  end

  @doc "Breadcrumb trail (space included) in Confluence order."
  def breadcrumbs(%Page{} = page, opts \\ []) do
    [
      %{
        title: page.space.name,
        space_key: page.space.key,
        homepage_confluence_id: page.space.homepage_confluence_id,
        kind: :space
      }
    ] ++ Enum.map(ancestor_crumbs(page.ancestors, opts), &Map.put(&1, :kind, :page))
  end

  # A crumb needs a title and a link to a page, not a page: three columns and no
  # space preload keep the trail to one statement instead of two.
  defp ancestor_crumbs(ids, opts) when is_list(ids) do
    pages =
      from(p in Page,
        as: :page,
        where: p.confluence_id in ^ids and is_nil(p.deleted_at),
        select: %{title: p.title, confluence_id: p.confluence_id, slug: p.slug}
      )
      |> filtered(opts)
      |> Repo.all()

    by_id = Map.new(pages, &{&1.confluence_id, &1})
    Enum.flat_map(ids, &List.wrap(by_id[&1]))
  end

  @doc "Ancestor pages in Confluence order (root first)."
  def ancestor_pages(page, opts \\ [])

  def ancestor_pages(%Page{ancestors: ids}, opts) when is_list(ids) do
    pages =
      from(p in Page,
        as: :page,
        where: p.confluence_id in ^ids and is_nil(p.deleted_at),
        preload: [:space]
      )
      |> filtered(opts)
      |> Repo.all()

    by_id = Map.new(pages, &{&1.confluence_id, &1})
    Enum.flat_map(ids, fn id -> List.wrap(by_id[id]) end)
  end

  def ancestor_pages(_page, _opts), do: []

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

  def get_space_home(space, opts \\ [])
  def get_space_home(%Space{homepage_confluence_id: nil}, _opts), do: nil

  def get_space_home(%Space{homepage_confluence_id: id}, opts) do
    # The overview and the redirect both know the space: the card needs a title,
    # a link and an excerpt, so the row is read without its body or its space.
    from(p in Page,
      as: :page,
      where: p.confluence_id == ^id and is_nil(p.deleted_at),
      select: %{
        id: p.id,
        space_id: p.space_id,
        confluence_id: p.confluence_id,
        type: p.type,
        title: p.title,
        slug: p.slug,
        body_text: p.body_text
      }
    )
    |> filtered(opts)
    |> Repo.one()
  end

  @doc "Blog posts of a space, newest first, as the overview's rail lists them."
  def blog_posts(space_id \\ nil, limit \\ 20, opts \\ []) do
    from(p in Page,
      as: :page,
      where: p.type == "blogpost" and is_nil(p.deleted_at),
      order_by: [desc: p.external_updated_at],
      limit: ^limit,
      select: %{
        id: p.id,
        space_id: p.space_id,
        confluence_id: p.confluence_id,
        type: p.type,
        title: p.title,
        slug: p.slug,
        author_name: p.author_name,
        external_updated_at: p.external_updated_at
      }
    )
    |> where_space(space_id)
    |> filtered(opts)
    |> Repo.all()
  end

  def backlinks(%Page{id: id}, opts \\ []) do
    from(p in Page,
      as: :page,
      join: l in assoc(p, :outgoing_links),
      where: l.target_page_id == ^id and is_nil(p.deleted_at),
      distinct: true,
      order_by: [asc: p.title],
      preload: [:space]
    )
    |> filtered(opts)
    |> Repo.all()
  end

  @doc """
  The links a page draws, in the order they appear.

  The rail shows a handful of them, so the window is asked of the database; a
  hub page with a thousand links is not worth a thousand rows per request.

  Options: `:limit` (default 12) and `:filter` — the restriction is applied to
  the page a link points at, through the `:page` binding on that left join, so a
  link whose target this reader may not open is never returned and the title it
  carries never leaves the database. A link with no target keeps its row: there
  is no page behind it to ask about.
  """
  def outgoing_links(%Page{id: id}, opts \\ []) do
    from(l in Link,
      left_join: t in assoc(l, :target_page),
      as: :page,
      where: l.source_page_id == ^id,
      order_by: [asc: l.inserted_at]
    )
    |> filtered(opts)
    |> limit_rows(Keyword.get(opts, :limit, 12))
    |> Repo.all()
  end

  def attachments(%Page{id: id}) do
    from(a in Attachment,
      where: a.page_id == ^id and is_nil(a.comment_id),
      order_by: [asc: a.filename]
    )
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
    from(c in Comment,
      where: c.page_id == ^id and is_nil(c.deleted_at),
      order_by: [asc: c.external_created_at]
    )
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

  def recent_pages_for_space(%Space{id: space_id}, limit, opts \\ []) do
    from(p in Page,
      as: :page,
      where: p.space_id == ^space_id and is_nil(p.deleted_at),
      order_by: [desc: p.external_updated_at],
      limit: ^limit,
      select: %{
        id: p.id,
        space_id: p.space_id,
        confluence_id: p.confluence_id,
        type: p.type,
        title: p.title,
        slug: p.slug,
        external_updated_at: p.external_updated_at
      }
    )
    |> filtered(opts)
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

  @doc "How many pages the mirror holds, across every space."
  def count_pages do
    Repo.one(from p in Page, where: is_nil(p.deleted_at), select: count(p.id))
  end

  @doc """
  Marks a page's comments, attachments and restrictions as read.

  A page's own version says nothing about its details: a reply arrives, a
  screenshot is pasted in, and the page stays at version 1. This stamp is what
  lets a later run ask "whose details have I never read?" and answer it.
  """
  def mark_details_synced(%Page{id: id}) do
    {1, _} =
      Repo.update_all(from(p in Page, where: p.id == ^id),
        set: [details_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    :ok
  end

  @doc """
  Pages whose details have never been read, oldest first.

  `:limit` is required: this is a backlog, and a run works through a slice of
  it rather than reading a hundred thousand pages' comments in one go.
  """
  def pages_awaiting_details(limit) do
    from(p in Page,
      where: is_nil(p.deleted_at) and is_nil(p.details_synced_at),
      order_by: [asc: p.id],
      limit: ^limit,
      select: p.confluence_id
    )
    |> Repo.all()
  end

  @doc """
  The pages among `confluence_ids` whose details have never been read.

  This is the backlog narrowed to what the site says actually has comments or
  files, so an upgrade re-reads the pages that can be missing something instead
  of every page in the mirror.
  """
  def pages_awaiting_details_among(confluence_ids, limit) do
    from(p in Page,
      where:
        p.confluence_id in ^confluence_ids and is_nil(p.deleted_at) and
          is_nil(p.details_synced_at),
      order_by: [asc: p.id],
      limit: ^limit,
      select: p.confluence_id
    )
    |> Repo.all()
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

  @doc "How many files a space holds, without reading them."
  def count_attachments_in_space(space_id, opts \\ []) do
    pages =
      from(p in Page,
        as: :page,
        where: p.space_id == ^space_id and is_nil(p.deleted_at),
        select: p.id
      )
      |> filtered(opts)

    from(a in Attachment,
      where: a.page_id in subquery(pages),
      select: count(a.id)
    )
    |> Repo.one()
  end

  @doc """
  Labels used in one space, with their page counts.

  Options: `:limit`, `:order` (`:name`, the default, or `:popular`) and
  `:filter`. Both the labels and their counts are computed over the pages the
  filter keeps, so a label that only a page the reader may not open carries does
  not appear — and a count does not include what its reader cannot read.
  """
  def labels_in_space(space_id, opts \\ []) do
    pages =
      from(p in Page,
        as: :page,
        where: p.space_id == ^space_id and is_nil(p.deleted_at),
        select: p.id
      )
      |> filtered(opts)

    from(l in Label,
      join: p in assoc(l, :pages),
      where: p.id in subquery(pages),
      group_by: l.id,
      select: {l.name, count(p.id)}
    )
    |> order_labels_in_space(Keyword.get(opts, :order, :name))
    |> limit_rows(Keyword.get(opts, :limit))
    |> Repo.all()
  end

  defp order_labels_in_space(query, :popular),
    do: order_by(query, [l], desc: count(l.id), asc: l.name)

  defp order_labels_in_space(query, _name), do: order_by(query, [l], asc: l.name)

  @doc """
  People who authored mirrored content, with page counts.

  Confluence's people directory is served from mirrored bylines rather than a
  separate user sync: the mirror never invents accounts it has not seen. The
  grouping is a pass over the pages table, so the answer is remembered until
  the content moves.
  """
  def authors(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    Counters.fetch({:authors, limit}, fn ->
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
      |> limit_rows(limit)
      |> Repo.all()
    end)
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

  @doc """
  What the mirror holds: spaces, pages, attachments, comments and labels.

  Five aggregates over tables that grow with the site, so it is computed once
  per content version rather than once per request.
  """
  def stats do
    Counters.fetch(:stats, fn ->
      Repo.one(
        from(s in Space,
          where: is_nil(s.deleted_at),
          select: %{
            spaces: count(s.id),
            pages: fragment("(SELECT count(*) FROM pages WHERE deleted_at IS NULL)"),
            attachments: fragment("(SELECT count(*) FROM attachments)"),
            comments: fragment("(SELECT count(*) FROM comments WHERE deleted_at IS NULL)"),
            labels: fragment("(SELECT count(*) FROM labels)")
          }
        )
      )
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
