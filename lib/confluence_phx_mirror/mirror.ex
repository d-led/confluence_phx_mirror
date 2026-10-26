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
  alias ConfluencePhxMirror.Audit
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
    |> revive_space()
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

  @doc """
  The rows that decide who may read a space, as the last sync read them plus
  whatever an administrator decided here.

  A row is one of three things, told apart by its overlay marker: the site's
  (`granted_by_id` and `revoked_by_id` both null), a grant here
  (`granted_by_id`), or a removal here (`revoked_by_id`). Empty means the space
  is open — except that a removal row is what stops a reader, so a space whose
  only rows are removals is closed rather than open.
  """
  def space_permissions(space_id) do
    from(c in SpacePermission,
      where: c.space_id == ^space_id and c.operation == "read",
      select: %{
        subject_type: c.subject_type,
        subject_key: c.subject_key,
        granted_by_id: c.granted_by_id,
        revoked_by_id: c.revoked_by_id
      }
    )
    |> Repo.all()
  end

  @doc """
  Who may read a space, as the last sync read it — what the admin's space page
  shows: groups, people, whether anonymous readers are included, and whose
  personal space it is.

  A user subject is stored under every identifier Confluence named it by (the
  account id and, when shared, the e-mail), so people are answered once per
  account where the mirror knows one. A personal space usually has no
  permission rows at all, so its owner is answered here rather than left to look
  like an open space.
  """
  def space_grants(%{id: space_id} = space) do
    space_id |> space_permissions() |> grants(space)
  end

  @doc """
  Who may read a page on top of its space: a page with read restrictions is
  readable only by the subjects listed here, whatever the space allows.
  """
  def page_grants(%Page{} = page) do
    from(r in PageRestriction,
      where: r.page_id == ^page.id and r.operation == "read",
      select: %{
        subject_type: r.subject_type,
        subject_key: r.subject_key,
        granted_by_id: r.granted_by_id,
        revoked_by_id: r.revoked_by_id
      }
    )
    |> Repo.all()
    |> grants(page.space)
  end

  @doc """
  The pages in a space that carry their own restrictions, with how many subjects
  narrow each — the questions the space view cannot answer.

  Bounded like every other list on a screen: a space can have thousands of
  pages, and the ones that are narrowed are the ones worth naming.
  """
  def restricted_pages(space_id, opts \\ []) do
    from(p in Page,
      join: r in PageRestriction,
      on: r.page_id == p.id,
      where:
        p.space_id == ^space_id and p.type == "page" and is_nil(p.deleted_at) and
          r.operation == "read",
      group_by: p.id,
      order_by: [asc: p.title],
      limit: ^Keyword.get(opts, :limit, 20),
      select: {p, count(r.id)}
    )
    |> Repo.all()
  end

  # One shape for "who may read this", whether the rows came from a space's
  # permissions, a page's restrictions or nothing at all.
  #
  # The site's rows and the mirror's own are answered apart: an administrator
  # checking the mirror against Confluence has to be able to tell "the space says
  # this" from "we added that" or "we took that away".
  #
  # `personal` is the narrowing that has no rows: a personal space belongs to one
  # account, and an empty permission table there means "one reader", not "open".
  # `narrowed?` is the question a screen asks before it says "open": any row at
  # all narrows, and so does a removal, because a space whose readers were all
  # taken away is closed, not open to everybody.
  defp grants(subjects, space) do
    synced = Enum.filter(subjects, &synced_row?/1)
    granted = Enum.filter(subjects, &granted_row?/1)
    removed = Enum.filter(subjects, &removed_row?/1)
    personal = personal_owner(space)

    %{
      groups:
        synced
        |> Enum.filter(&(&1.subject_type == "group"))
        |> Enum.map(& &1.subject_key)
        |> Enum.uniq()
        |> Enum.sort(),
      users: user_grants(synced),
      anonymous: Enum.any?(synced, &(&1.subject_type == "anonymous")),
      personal: personal,
      synced?: synced != [],
      granted: with_accounts(granted),
      removed: with_accounts(removed),
      narrowed?: subjects != [] or personal != nil
    }
  end

  defp synced_row?(%{granted_by_id: nil, revoked_by_id: nil}), do: true
  defp synced_row?(_subject), do: false

  defp granted_row?(%{granted_by_id: id}), do: not is_nil(id)
  defp granted_row?(_subject), do: false

  defp removed_row?(%{revoked_by_id: id}), do: not is_nil(id)
  defp removed_row?(_subject), do: false

  # The overlay rows, with the name a screen wants to show for a person.
  defp with_accounts([]), do: []

  defp with_accounts(rows) do
    accounts = user_grants(Enum.filter(rows, &(&1.subject_type == "user")))

    Enum.map(rows, fn row ->
      case Enum.find(accounts, &(&1.key == row.subject_key)) do
        nil -> row
        account -> Map.put(row, :label, account.label)
      end
    end)
  end

  @doc """
  The account id a personal space belongs to, or nil for an ordinary space.

  A personal space's key is `~` and its owner's account id; `Authorization`
  enforces that, and this is the same fact spelled for a screen.
  """
  def personal_owner(%{type: "personal", key: key}) when is_binary(key),
    do: key |> String.trim_leading("~") |> String.downcase()

  def personal_owner(_space), do: nil

  @doc """
  Whether anything narrows this space at all — rows of any kind, or being
  somebody's own.

  The question a screen asks before it says "open", because an empty permission
  table on a personal space means one reader, not everybody, and a table whose
  readers were all removed means nobody.
  """
  def narrowed?(grants), do: grants.narrowed?

  @doc """
  How access is reported for a page of spaces: subject counts per space, in one
  statement rather than one per row.

  A space the answer does not name has no mirrored permissions, which means
  nothing narrows it — the screen can say that in a word instead of drawing an
  empty list next to "everybody can read this". A space named only by removals is
  narrowed to nobody, so the summary carries those apart from the readers who
  may still open it.
  """
  def space_access_by(space_ids) when is_list(space_ids) do
    from(p in SpacePermission,
      where: p.operation == "read" and p.space_id in ^space_ids,
      select: {p.space_id, p.subject_type, p.subject_key, p.revoked_by_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_id, type, key, revoked} ->
      %{subject_type: type, subject_key: key, removed?: not is_nil(revoked)}
    end)
    |> Map.new(fn {space_id, subjects} -> {space_id, access_summary(subjects)} end)
  end

  defp access_summary(subjects) do
    readers = Enum.reject(subjects, & &1.removed?)

    %{
      groups:
        readers
        |> Enum.filter(&(&1.subject_type == "group"))
        |> Enum.map(& &1.subject_key)
        |> Enum.uniq()
        |> length(),
      users:
        readers
        |> Enum.filter(&(&1.subject_type == "user"))
        |> Enum.map(& &1.subject_key)
        |> Enum.uniq()
        |> length(),
      anonymous: Enum.any?(readers, &(&1.subject_type == "anonymous")),
      removed: length(subjects) - length(readers)
    }
  end

  # No row names a person, so no account has to be looked up: the screen asks
  # this once per level and the budget counts statements.
  defp user_grants([]), do: []

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

  @doc """
  The readers this mirror added to a space, apart from the ones the sync read.

  A grant is a `space_permissions` row with `granted_by_id` set: one table, so
  every access rule sees it without learning a second concept, and a marker, so a
  screen can say which rows are the site's and which are ours.
  """
  def space_grants_here(%{id: space_id}) do
    from(p in SpacePermission,
      where: p.space_id == ^space_id and p.operation == "read" and not is_nil(p.granted_by_id),
      order_by: [asc: p.subject_type, asc: p.subject_key]
    )
    |> Repo.all()
  end

  @doc """
  Lets one more reader into a space the site narrows — the mirror's own decision.

  A user is named by a key the mirror knows (an account id or an e-mail), a group
  by a name the sync has read; nothing is invented here. Only an administrator may
  grant, and the grant is in the audit log. An open space is refused: there is
  nothing to widen, and a row there would read as "this is what narrows it".
  """
  def grant_space_access(space, subject_type, subject_key, actor)
      when subject_type in ["user", "group"] and is_binary(subject_key) do
    with :ok <- authorize_grant(actor),
         :ok <- refuse_open_space(space),
         :ok <- refuse_unknown(subject_type, subject_key),
         {:ok, row} <- insert_grant(space, subject_type, subject_key, actor) do
      Audit.log(actor, SpacePermission.audit_event_granted(row, space.key))
      {:ok, row}
    end
  end

  @doc "Takes that reader away again, on the same authority."
  def revoke_space_access(space, subject_type, subject_key, actor) do
    with :ok <- authorize_grant(actor),
         %SpacePermission{} = row <- find_grant(space, subject_type, subject_key) do
      {:ok, removed} = Repo.delete(row)
      Audit.log(actor, SpacePermission.audit_event_revoked(removed, space.key))
      {:ok, removed}
    else
      nil -> {:error, :not_granted}
      error -> error
    end
  end

  @doc """
  Stops an identity the site lists from reading this space — the mirror's own
  decision, made the other way round from a grant.

  The site's row is not deleted: it becomes a removal row, so the next run
  neither loses the decision nor puts the reader back. Only an identity the site
  actually lists can be removed — taking away a reader who was never named here
  would be a decision about nothing. A removal is in the audit log.
  """
  def remove_space_reader(space, subject_type, subject_key, actor) do
    with :ok <- authorize_grant(actor),
         %SpacePermission{} = row <-
           find_synced_row(SpacePermission, :space_id, space.id, subject_type, subject_key),
         {:ok, removed} <- mark_removed(row, actor) do
      Audit.log(actor, SpacePermission.audit_event_removed(removed, space.key))
      {:ok, removed}
    else
      nil -> {:error, :not_listed}
      error -> error
    end
  end

  @doc "Lets a reader the site lists back in, undoing a removal made here."
  def restore_space_reader(space, subject_type, subject_key, actor) do
    with :ok <- authorize_grant(actor),
         %SpacePermission{} = row <-
           find_removal(SpacePermission, :space_id, space.id, subject_type, subject_key),
         {:ok, restored} <- unmark_removed(row) do
      Audit.log(actor, SpacePermission.audit_event_restored(restored, space.key))
      {:ok, restored}
    else
      nil -> {:error, :not_removed}
      error -> error
    end
  end

  defp find_grant(space, subject_type, subject_key) do
    Repo.one(
      from p in SpacePermission,
        where:
          p.space_id == ^space.id and p.operation == "read" and
            p.subject_type == ^subject_type and p.subject_key == ^subject_key and
            not is_nil(p.granted_by_id)
    )
  end

  defp insert_grant(space, subject_type, subject_key, actor) do
    %SpacePermission{}
    |> SpacePermission.changeset(%{
      space_id: space.id,
      operation: "read",
      subject_type: subject_type,
      subject_key: subject_key,
      granted_by_id: granted_by_id(actor)
    })
    |> Repo.insert()
  end

  defp granted_by_id({:user, %User{id: id}}), do: id
  defp granted_by_id(_actor), do: nil

  # The site's own row, at either level: neither overlay marker is set.
  defp find_synced_row(SpacePermission, :space_id, id, subject_type, subject_key) do
    Repo.one(
      from c in SpacePermission,
        where:
          c.space_id == ^id and c.operation == "read" and c.subject_type == ^subject_type and
            c.subject_key == ^subject_key and is_nil(c.granted_by_id) and
            is_nil(c.revoked_by_id)
    )
  end

  defp find_synced_row(PageRestriction, :page_id, id, subject_type, subject_key) do
    Repo.one(
      from r in PageRestriction,
        where:
          r.page_id == ^id and r.operation == "read" and r.subject_type == ^subject_type and
            r.subject_key == ^subject_key and is_nil(r.granted_by_id) and
            is_nil(r.revoked_by_id)
    )
  end

  defp find_removal(SpacePermission, :space_id, id, subject_type, subject_key) do
    Repo.one(
      from c in SpacePermission,
        where:
          c.space_id == ^id and c.operation == "read" and c.subject_type == ^subject_type and
            c.subject_key == ^subject_key and not is_nil(c.revoked_by_id)
    )
  end

  defp find_removal(PageRestriction, :page_id, id, subject_type, subject_key) do
    Repo.one(
      from r in PageRestriction,
        where:
          r.page_id == ^id and r.operation == "read" and r.subject_type == ^subject_type and
            r.subject_key == ^subject_key and not is_nil(r.revoked_by_id)
    )
  end

  # The row becomes the mirror's own: still the subject the site names, now with
  # the mark that says we are the ones refusing them.
  defp mark_removed(row, actor) do
    row
    |> Ecto.Changeset.change(granted_by_id: nil, revoked_by_id: granted_by_id(actor))
    |> Repo.update()
  end

  # Back to the site's row: the next run replaces it with what the site says,
  # which is exactly what a restored reader should get.
  defp unmark_removed(row) do
    row |> Ecto.Changeset.change(revoked_by_id: nil) |> Repo.update()
  end

  # The same question administration asks, asked here so no surface can bypass it
  # by calling the context directly.
  defp authorize_grant({:user, %User{} = actor}) do
    if ConfluencePhxMirror.Accounts.Admins.admin?(actor), do: :ok, else: {:error, :not_authorized}
  end

  defp authorize_grant(_actor), do: {:error, :not_authorized}

  # A grant adds a reader to a space that is narrowed. On an open space it would be
  # a row that reads like a restriction and narrows nothing.
  defp refuse_open_space(%{id: space_id}) do
    if space_permissions(space_id) == [], do: {:error, :space_is_open}, else: :ok
  end

  defp refuse_unknown("user", subject_key) do
    if identity_known?([subject_key]), do: :ok, else: {:error, :unknown_identity}
  end

  defp refuse_unknown("group", subject_key) do
    if subject_key in synced_group_names(), do: :ok, else: {:error, :unknown_group}
  end

  @doc "Replaces what we know about who may read a space."
  def replace_space_permissions(%Space{} = space, permissions) do
    replace_subjects(SpacePermission, :space_id, space.id, permissions)
  end

  @doc "Subjects that may read a page; empty means it is unrestricted."
  def page_restrictions(confluence_id) do
    from(r in PageRestriction,
      join: p in Page,
      on: p.id == r.page_id,
      where: p.confluence_id == ^confluence_id and r.operation == "read",
      select: %{
        subject_type: r.subject_type,
        subject_key: r.subject_key,
        granted_by_id: r.granted_by_id,
        revoked_by_id: r.revoked_by_id
      }
    )
    |> Repo.all()
  end

  @doc """
  Lets one more reader onto a page the site restricted — the mirror's own
  decision, on the same authority and the same rules as a space: an
  administrator, a subject the mirror knows, and a page that is already narrowed.
  """
  def grant_page_access(%Page{} = page, subject_type, subject_key, actor)
      when subject_type in ["user", "group"] and is_binary(subject_key) do
    with :ok <- authorize_grant(actor),
         :ok <- refuse_unrestricted_page(page),
         :ok <- refuse_unknown(subject_type, subject_key),
         {:ok, row} <- insert_restriction(page, subject_type, subject_key, actor) do
      Audit.log(actor, PageRestriction.audit_event_granted(row, page.title))
      {:ok, row}
    end
  end

  @doc "Takes that reader off the page again."
  def revoke_page_access(%Page{} = page, subject_type, subject_key, actor) do
    with :ok <- authorize_grant(actor),
         %PageRestriction{} = row <- find_restriction(page, subject_type, subject_key) do
      {:ok, removed} = Repo.delete(row)
      Audit.log(actor, PageRestriction.audit_event_revoked(removed, page.title))
      {:ok, removed}
    else
      nil -> {:error, :not_granted}
      error -> error
    end
  end

  @doc """
  Stops an identity the site lists on a page from reading it here, the way
  `remove_space_reader/4` does for a space: the site's row stays, marked as the
  mirror's refusal, and the next run leaves it alone.
  """
  def remove_page_reader(%Page{} = page, subject_type, subject_key, actor) do
    with :ok <- authorize_grant(actor),
         %PageRestriction{} = row <-
           find_synced_row(PageRestriction, :page_id, page.id, subject_type, subject_key),
         {:ok, removed} <- mark_removed(row, actor) do
      Audit.log(actor, PageRestriction.audit_event_removed(removed, page.title))
      {:ok, removed}
    else
      nil -> {:error, :not_listed}
      error -> error
    end
  end

  @doc "Lets a reader the site lists back onto the page, undoing a removal here."
  def restore_page_reader(%Page{} = page, subject_type, subject_key, actor) do
    with :ok <- authorize_grant(actor),
         %PageRestriction{} = row <-
           find_removal(PageRestriction, :page_id, page.id, subject_type, subject_key),
         {:ok, restored} <- unmark_removed(row) do
      Audit.log(actor, PageRestriction.audit_event_restored(restored, page.title))
      {:ok, restored}
    else
      nil -> {:error, :not_removed}
      error -> error
    end
  end

  defp find_restriction(page, subject_type, subject_key) do
    Repo.one(
      from r in PageRestriction,
        where:
          r.page_id == ^page.id and r.operation == "read" and
            r.subject_type == ^subject_type and r.subject_key == ^subject_key and
            not is_nil(r.granted_by_id)
    )
  end

  defp insert_restriction(page, subject_type, subject_key, actor) do
    %PageRestriction{}
    |> PageRestriction.changeset(%{
      page_id: page.id,
      operation: "read",
      subject_type: subject_type,
      subject_key: subject_key,
      granted_by_id: granted_by_id(actor)
    })
    |> Repo.insert()
  end

  # A grant adds a reader to a page that is narrowed. On an unrestricted page it
  # would be the row that restricts it — the opposite of what it says.
  defp refuse_unrestricted_page(page) do
    if page_restriction_rows(page.id) == [], do: {:error, :page_is_open}, else: :ok
  end

  defp page_restriction_rows(page_id) do
    from(r in PageRestriction, where: r.page_id == ^page_id and r.operation == "read")
    |> Repo.all()
  end

  @doc "Replaces what we know about who may read a page."
  def replace_page_restrictions(%Page{} = page, restrictions) do
    replace_subjects(PageRestriction, :page_id, page.id, restrictions)
  end

  # The sync replaces the rows it wrote and nothing else. A row an administrator
  # granted or removed here outlives every run — that is the point of the
  # overlay — and a target the site opens again has neither anything to widen nor
  # anything to take away, so its overlay rows go: neither may be the reason a
  # page or a space is narrowed.
  #
  # A subject the site still lists but an administrator removed here is not
  # written back, or the two rows would fight over the same unique key. Anything
  # else the site names is written even if a grant already holds that key
  # (`on_conflict: :nothing`), because a grant and the site agreeing is not an
  # error.
  defp replace_subjects(schema, foreign_key, id, subjects) do
    queryable = subject_scope(schema, foreign_key, id)

    Repo.transaction(fn ->
      wipe_overlay? = subjects == []

      Repo.delete_all(
        from c in queryable,
          where: (is_nil(c.granted_by_id) and is_nil(c.revoked_by_id)) or ^wipe_overlay?
      )

      insert_subjects(schema, foreign_key, id, reject_removed(subjects, removed_keys(queryable)))
    end)
  end

  defp subject_scope(SpacePermission, :space_id, space_id) do
    from(c in SpacePermission, where: c.space_id == ^space_id)
  end

  defp subject_scope(PageRestriction, :page_id, page_id) do
    from(r in PageRestriction, where: r.page_id == ^page_id)
  end

  defp removed_keys(queryable) do
    from(c in queryable,
      where: not is_nil(c.revoked_by_id),
      select: {c.subject_type, c.subject_key}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp reject_removed(subjects, removed) do
    if MapSet.size(removed) == 0 do
      subjects
    else
      Enum.reject(subjects, fn subject ->
        MapSet.member?(removed, {to_string(subject.subject_type), subject.subject_key || ""})
      end)
    end
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

    if rows == [], do: 0, else: Repo.insert_all(schema, rows, on_conflict: :nothing)
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

  `:query` is a term matched against the name Confluence shows and the account id
  the permissions name, because a list that size is searched rather than
  browsed.
  """
  def people(opts \\ []) do
    page = identities_page(opts)
    groups = groups_by_subject(Enum.map(page, & &1.account_id))

    Enum.map(page, &Map.put(&1, :groups, Map.get(groups, &1.account_id, [])))
  end

  @doc "How many people the content names, for the screen's \"of N\"."
  def count_people(opts \\ []) do
    identities_query(opts)
    |> subquery()
    |> select([i], count())
    |> Repo.one()
  end

  defp identities_page(opts) do
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    identities_query(opts)
    |> order_by([i], asc: coalesce(max(i.display_name), i.account_id))
    |> limit_if(limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp limit_if(query, nil), do: query
  defp limit_if(query, limit), do: limit(query, ^limit)

  # One row per person, however often the content names them.
  defp identities_query(opts) do
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
    |> identities_matching(Keyword.get(opts, :query))
    |> group_by([i], i.account_id)
    |> select([i], %{account_id: i.account_id, display_name: max(i.display_name)})
  end

  # A name Confluence shows and an account id the permissions name are both
  # searched, case-insensitively, on the pattern the catalogs already use.
  defp identities_matching(query, blank) when blank in [nil, ""], do: query

  defp identities_matching(query, term) do
    pattern = "%" <> (term |> to_string() |> String.trim() |> String.downcase()) <> "%"

    where(
      query,
      [i],
      fragment("lower(coalesce(?, '')) like ?", i.display_name, ^pattern) or
        fragment("lower(?) like ?", i.account_id, ^pattern)
    )
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
  site's users through the API — so "somebody of the site" means "the mirror has
  read about this person": a member of a group the content mentions, somebody a
  space permission or a page restriction names, or the author of a page or a
  comment. Authorship counts because the rule this mirror keeps is that whoever
  may read on Confluence may read here — an author is on the site even before a
  group or a permission has listed them. Mirror administrators are a separate
  question, answered by `ConfluencePhxMirror.Accounts.Admins`.

  Identities are matched case-insensitively, like the permission checks do.
  """
  @spec identity_known?([String.t() | nil]) :: boolean()
  def identity_known?(subject_keys) do
    subjects = subject_keys |> Enum.reject(&is_nil/1) |> Enum.map(&String.downcase/1)

    subjects != [] and (listed?(subjects) or authored?(subjects))
  end

  # A group the sync lists, or somebody a space permission or page restriction
  # names. Matched case-insensitively, like the permission checks do.
  defp listed?(subjects) do
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

  # The people the content itself names.
  defp authored?(subjects) do
    page =
      from(p in Page,
        where: fragment("lower(?)", p.author_account_id) in ^subjects,
        limit: 1,
        select: 1
      )

    comment =
      from(c in Comment,
        where: fragment("lower(?)", c.author_account_id) in ^subjects,
        limit: 1,
        select: 1
      )

    Repo.exists?(page) or Repo.exists?(comment)
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

  @doc """
  A page by its row id — what a list on a screen hands back, as against the
  Confluence id a URL carries.
  """
  def get_page_by_id!(id) do
    Repo.one!(
      from p in Page,
        where: p.id == ^id and is_nil(p.deleted_at),
        preload: [:space]
    )
  end

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

  @doc """
  Finds a page by space key and exact title.

  Confluence keeps titles unique within a space, and a caller that has a title
  in hand (a person quoting a page, an assistant that saw it in a list) should
  not have to resolve an id first. The comparison is exact, like Confluence's
  own: a near miss is a different page.
  """
  def find_page_by_title(space_key, title) do
    from(p in Page,
      join: s in assoc(p, :space),
      where: s.key == ^String.upcase(space_key) and p.title == ^title and is_nil(p.deleted_at),
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
    |> revive_page()
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

    trash_pages(ids, now, "vanished")
    length(ids)
  end

  @doc """
  Records which of `space`'s pages the site's own listing did not name.

  A page the listing names is one the site still publishes, so whatever absence
  it carried is cleared. A page it does not name gets `absent_since` — the first
  time the mirror noticed, kept on later passes so the review screen can say how
  long something has been gone.

  Nothing is trashed here. A listing is evidence, and what a listing leaves out
  can also be a permission the token lost or a space it may no longer read, so
  an administrator decides (see `ConfluencePhxMirror.Trash`). Returns
  `{newly_absent, still_there}`.
  """
  @spec mark_absent(Space.t(), [integer()]) :: {non_neg_integer(), non_neg_integer()}
  def mark_absent(%Space{} = space, seen_confluence_ids) do
    now = now()
    seen = Enum.to_list(seen_confluence_ids)

    {cleared, _} =
      from(p in Page,
        where:
          p.space_id == ^space.id and not is_nil(p.absent_since) and
            p.confluence_id in ^seen
      )
      |> Repo.update_all(set: [absent_since: nil, updated_at: now])

    ids =
      from(p in Page,
        where:
          p.space_id == ^space.id and is_nil(p.deleted_at) and
            is_nil(p.absent_since) and p.confluence_id not in ^seen,
        select: p.id
      )
      |> Repo.all()

    {marked, _} =
      from(p in Page, where: p.id in ^ids)
      |> Repo.update_all(set: [absent_since: now, updated_at: now])

    {marked, cleared}
  end

  @doc """
  Live pages the site did not list, newest absence first.

  Options: `:space_id`, `:limit`.
  """
  def absent_pages(opts \\ []) do
    query =
      from(p in Page,
        join: s in assoc(p, :space),
        where: is_nil(p.deleted_at) and not is_nil(p.absent_since),
        order_by: [desc: p.absent_since, asc: p.title],
        limit: ^Keyword.get(opts, :limit),
        select: {p, s}
      )

    case Keyword.get(opts, :space_id) do
      nil -> query
      space_id -> where(query, [p, _s], p.space_id == ^space_id)
    end
    |> Repo.all()
  end

  @doc "How many live spaces the mirror holds — what a check has to get through."
  def count_spaces do
    Repo.aggregate(from(s in Space, where: is_nil(s.deleted_at)), :count)
  end

  @doc """
  How many absent pages each space holds, most first.

  The review screen starts here: an operator sees which spaces disagree with the
  site before reading a single page title.
  """
  def absent_spaces do
    from(p in Page,
      join: s in assoc(p, :space),
      where: is_nil(p.deleted_at) and not is_nil(p.absent_since),
      group_by: [s.id, s.key, s.name],
      order_by: [desc: count(p.id)],
      select: %{space: s, pages: count(p.id), since: min(p.absent_since)}
    )
    |> Repo.all()
  end

  @doc "How many live pages the site did not list."
  def count_absent do
    Repo.one(
      from p in Page,
        where: is_nil(p.deleted_at) and not is_nil(p.absent_since),
        select: count(p.id)
    )
  end

  @doc "How many live pages of `space` the site did not list."
  def count_absent(space_id) do
    Repo.one(
      from p in Page,
        where: p.space_id == ^space_id and is_nil(p.deleted_at) and not is_nil(p.absent_since),
        select: count(p.id)
    )
  end

  @doc """
  Moves every absent page of `space` to the trash, saying why they left.

  One statement for the pages and one for their comments, both driven by a
  subquery — the ids never travel through Elixir. That is what makes a space with
  tens of thousands of absent pages safe to clear: reading them first would hold
  the whole list in memory and then send it back as one `IN` clause, which is
  both slow and, past Postgres' parameter limit, a job that cannot run at all.

  The mirror keeps the rows (and their comments) for the audit trail; an
  administrator purges them from `/admin/trash` when the decision is final.
  Returns how many pages moved.
  """
  @spec trash_absent_pages(Space.t()) :: non_neg_integer()
  def trash_absent_pages(%Space{} = space) do
    {:ok, trashed} =
      Repo.transaction(fn ->
        now = now()
        absent = absent_page_ids(space)

        # Everything that hangs off the pages goes first, while `absent_since` is
        # still what selects them; the update below clears it.
        from(r in PageRestriction, where: r.page_id in subquery(absent))
        |> mirror_rows()
        |> Repo.delete_all()

        from(c in Comment, where: c.page_id in subquery(absent) and is_nil(c.deleted_at))
        |> Repo.update_all(set: [deleted_at: now, updated_at: now])

        {trashed, _} =
          from(p in Page, where: p.id in subquery(absent))
          |> Repo.update_all(
            set: [deleted_at: now, deleted_reason: "vanished", absent_since: nil, updated_at: now]
          )

        trashed
      end)

    trashed
  end

  defp absent_page_ids(space) do
    from(p in Page,
      where: p.space_id == ^space.id and is_nil(p.deleted_at) and not is_nil(p.absent_since),
      select: p.id
    )
  end

  @doc """
  Marks one page deleted, keeping it for the audit trail and the trash.

  `reason` is `"manual"` when an administrator chose the page and `"vanished"`
  when a listing left it out.
  """
  def mark_deleted(confluence_id, reason \\ "manual") do
    case Repo.get_by(Page, confluence_id: confluence_id) do
      nil ->
        {:error, :not_found}

      page ->
        now = now()

        page =
          page
          |> Ecto.Changeset.change(deleted_at: now, deleted_reason: reason)
          |> Repo.update!()

        trash_comments([page.id], now)
        discard_page_overlays([page.id])
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

    trash_pages(ids, now, "vanished")
    discard_space_overlay(space.id)

    from(s in Space, where: s.id == ^space.id and is_nil(s.deleted_at))
    |> Repo.update_all(set: [deleted_at: now, updated_at: now])

    length(ids)
  end

  @doc """
  Spaces in the trash, newest first, with the number of pages that go with each.

  Option `:older_than` keeps only what was trashed at or before that moment —
  the question a retention policy asks (see `ConfluencePhxMirror.Trash`).
  """
  def trashed_spaces(opts \\ []) do
    query =
      from(s in Space,
        where: not is_nil(s.deleted_at),
        order_by: [desc: s.deleted_at],
        select: {s, fragment("(SELECT count(*) FROM pages p WHERE p.space_id = ?)", s.id)}
      )

    case Keyword.get(opts, :older_than) do
      nil -> query
      cutoff -> where(query, [s, _pages], s.deleted_at <= ^cutoff)
    end
    |> Repo.all()
  end

  @doc """
  Trashed pages and blog posts that did not go with a trashed space.

  Options: `:type` (`"page"` or `"blogpost"`), `:limit`, and `:older_than` —
  which keeps only what was trashed at or before that moment, the question a
  retention policy asks.
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

    query =
      case Keyword.get(opts, :type) do
        nil -> query
        type -> where(query, [p, _s], p.type == ^type)
      end

    case Keyword.get(opts, :older_than) do
      nil -> query
      cutoff -> where(query, [p, _s], p.deleted_at <= ^cutoff)
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
  #
  # Two halves to that, because the trash holds two different things:
  #
  #   * "vanished" is the mirror's own inference, drawn from a listing that left
  #     the page out. A page the site has just handed us disproves it, so it is
  #     lifted;
  #   * "manual" is an administrator's decision, and stays (`lift_vanishing/1`).
  #
  # A page we have just read is also not *absent*: an absence is a verdict from a
  # listing that is older than this write, and carrying it further would keep a
  # page we hold in the review list of pages the site no longer names. A space has
  # only the first of those two states, so it is cleared by its own helper.
  defp revive_page(changeset) do
    changeset
    |> Ecto.Changeset.put_change(:absent_since, nil)
    |> lift_vanishing()
  end

  # A page an administrator trashed (`mark_deleted/2`) stays trashed: a sync does
  # not get to undo a person's decision, and the page waits for a purge.
  defp lift_vanishing(%{data: %{deleted_reason: "manual"}} = changeset), do: changeset

  defp lift_vanishing(changeset) do
    changeset
    |> Ecto.Changeset.put_change(:deleted_at, nil)
    |> Ecto.Changeset.put_change(:deleted_reason, nil)
  end

  defp revive_space(changeset), do: Ecto.Changeset.put_change(changeset, :deleted_at, nil)

  defp trash_pages([], _now, _reason), do: 0

  defp trash_pages(ids, now, reason) do
    {pages, _} =
      from(p in Page, where: p.id in ^ids)
      |> Repo.update_all(
        set: [deleted_at: now, deleted_reason: reason, absent_since: nil, updated_at: now]
      )

    trash_comments(ids, now)
    discard_page_overlays(ids)
    pages
  end

  # A page that leaves the mirror takes the mirror's own access decisions with
  # it. A grant or a removal is about a page somebody could open, and a trashed
  # page is not one; keeping them would also mean a page that comes back carried
  # a decision nobody re-made. The site's rows stay for the audit trail — a
  # revived page is re-read from the source anyway.
  defp discard_page_overlays(page_ids) do
    from(r in PageRestriction, where: r.page_id in ^page_ids)
    |> mirror_rows()
    |> Repo.delete_all()
  end

  # The rows this mirror wrote rather than the site: a grant or a removal.
  defp mirror_rows(queryable) do
    from(r in queryable, where: not is_nil(r.granted_by_id) or not is_nil(r.revoked_by_id))
  end

  defp discard_space_overlay(space_id) do
    from(c in SpacePermission,
      where:
        c.space_id == ^space_id and
          (not is_nil(c.granted_by_id) or not is_nil(c.revoked_by_id))
    )
    |> Repo.delete_all()
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
  Every page below `page`, transitively, one level at a time.

  `ancestors` is the trail the sync denormalises onto each page, so a descendant
  is a row that names the page in that array: one statement backed by the GIN
  index answers a subtree of any size, however deep. A branch can be hundreds of
  pages, so the window (`:start`, `:limit`) and the total are read the way every
  other catalogue reads them, instead of loading the subtree to count it.

  Options: `:start` — rows to skip (default 0); `:limit`; `:filter` — an
  authorization narrowing over the `:page` binding.

  Returns `%{items: [%Page{}], total: count}` in level order — every page before
  the pages below it, siblings by title — with each row's `ancestors` intact, so
  a caller can say how far below `page` it sits (`Mirror.Page.depth_below/2`).
  """
  def descendants(%Page{confluence_id: id}, opts \\ []) do
    query =
      from(p in Page,
        as: :page,
        where: is_nil(p.deleted_at),
        where: fragment("? = ANY(?)", ^id, p.ancestors)
      )
      |> filtered(opts)

    %{
      items:
        query
        |> order_by([p],
          asc: fragment("cardinality(?)", p.ancestors),
          asc: p.title,
          asc: p.confluence_id
        )
        |> offset(^max(Keyword.get(opts, :start, 0), 0))
        |> limit_rows(Keyword.get(opts, :limit))
        |> preload(:space)
        |> Repo.all(),
      total: query |> select([p], count(p.id)) |> Repo.one()
    }
  end

  @doc """
  Every page of a space as the fields a page tree needs.

  The sidebar learned this the expensive way: a tree needs ids, titles and
  parents, not bodies, and selecting whole rows made one space map cost as much
  as its content. This is the same six columns for a caller that wants the whole
  space at once (the MCP server's `confluence_get_space_page_tree`).

  Options: `:limit` (rows, plus one read to say whether the tree was cut) and
  `:filter` (an authorization narrowing over the `:page` binding).

  Returns `%{rows: [row], truncated?: boolean}` in sibling order.
  """
  def space_tree(space_id, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    rows =
      from(p in Page,
        as: :page,
        where: p.space_id == ^space_id and is_nil(p.deleted_at),
        order_by: [asc: p.title],
        select: %{
          id: p.id,
          confluence_id: p.confluence_id,
          parent_id: p.parent_id,
          type: p.type,
          title: p.title,
          slug: p.slug,
          ancestors: p.ancestors,
          external_updated_at: p.external_updated_at
        }
      )
      |> limit_rows(limit && limit + 1)
      |> filtered(opts)
      |> Repo.all()

    if limit && length(rows) > limit do
      %{rows: Enum.take(rows, limit), truncated?: true}
    else
      %{rows: rows, truncated?: false}
    end
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

  @doc """
  The most recent sync runs, newest first.

  Ingestion history, not content: a caller that shows it decides who may see
  it, the way `/admin` does.
  """
  def recent_sync_runs(limit \\ 5) do
    from(r in SyncRun, order_by: [desc: r.started_at], limit: ^limit)
    |> Repo.all()
  end

  @doc """
  Spaces by when the sync last read them, newest first, with page counts.

  `spaces_with_counts/0` is a directory page and is cached; this answers "what
  was indexed last", so the ordering and the window belong to the database.
  `:key` narrows it to one space, for "when was this one last read?".
  """
  def spaces_by_last_sync(limit, opts \\ []) do
    from(s in Space,
      left_join: p in assoc(s, :pages),
      where: is_nil(s.deleted_at) and is_nil(p.deleted_at),
      where: ^last_sync_key(Keyword.get(opts, :key)),
      group_by: s.id,
      order_by: [desc_nulls_last: s.synced_at, asc: s.name],
      limit: ^limit,
      select: {s.key, s.name, s.synced_at, count(p.id)}
    )
    |> Repo.all()
  end

  defp last_sync_key(nil), do: dynamic(true)
  defp last_sync_key(key), do: dynamic([s], s.key == ^String.upcase(key))

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
  Live pages of `space`, counted per content type.

  A verify pass compares these with what the site says it holds
  (`ConfluencePhxMirror.Sync.Reconcile`): when the two agree there is nothing to
  list, which is the whole reason the pass is cheap.
  """
  @spec count_pages_by_type(integer()) :: %{page: non_neg_integer(), blogpost: non_neg_integer()}
  def count_pages_by_type(space_id) do
    counts =
      from(p in Page,
        where: p.space_id == ^space_id and is_nil(p.deleted_at),
        group_by: p.type,
        select: {p.type, count(p.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{page: Map.get(counts, "page", 0), blogpost: Map.get(counts, "blogpost", 0)}
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
  Says a page's details are stale — its version moved, so its comments, files
  and restrictions are whatever the sync is about to read.

  Clearing the mark is what makes an interrupted detail pass recoverable: the
  backlog (`pages_awaiting_details/1`) reads NULL, so a page whose work was
  stopped is read again by the next run instead of keeping a new body beside
  old comments forever.
  """
  def mark_details_stale(%Page{id: id}) do
    Repo.update_all(from(p in Page, where: p.id == ^id), set: [details_synced_at: nil])
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
  What the mirror holds: spaces, pages, attachments, comments and labels — and
  what is in its trash.

  Aggregates over tables that grow with the site, so it is computed once per
  content version rather than once per request. The trash is part of the same
  answer because an operator asking "how big is this" is also asking "how much
  of it is deleted but not gone yet".
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
            labels: fragment("(SELECT count(*) FROM labels)"),
            trashed_pages: fragment("(SELECT count(*) FROM pages WHERE deleted_at IS NOT NULL)"),
            trashed_spaces: fragment("(SELECT count(*) FROM spaces WHERE deleted_at IS NOT NULL)")
          }
        )
      )
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
