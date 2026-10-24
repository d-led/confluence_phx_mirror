defmodule ConfluencePhxMirror.Authorization do
  @moduledoc """
  Who may read what, replayed from what the sync learned from Confluence.

  Three levels, in Confluence's own precedence:

    1. a page with read restrictions is readable only by the listed users and
       groups;
    2. otherwise the space's read permissions decide;
    3. a space without synced permissions is open — the mirror already shows
       only what the sync account can read, and there is nothing else to go on.

  One space type overrides all three: a personal space belongs to the person
  whose account id keys it (`~5F057CBE0B38B10022628D68), and nobody else may
  read it, whatever permissions it has or lacks. A mirror usually skips personal
  spaces, but `CM_SYNC_PERSONAL_SPACES=true` mirrors them and a one-space sync
  may bring one in, and neither is a reason to show one person's drafts to the
  office.

  Mirror administrators always see everything — including personal spaces, which
  an administrator may have to look at to decide whether to keep mirroring them.

  A reader is matched by every identity their account stands for: its e-mail
  address, the identity it signed in with, and any further Confluence identity an
  administrator linked to it (`User.identity_keys/1`). One identity belongs to
  one account. Groups come from the membership the sync reads from Confluence,
  plus any group an administrator granted here.


  The decision is a pure function of the `Scope` and the mirror's tables, which
  is what makes it cheap to call from controllers, LiveViews and the API alike.
  """

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{PageRestriction, Space, SpacePermission}
  alias ConfluencePhxMirror.Repo

  import Ecto.Query

  @doc "Whether the reader may see a space (and therefore its catalogue entry)."
  @spec can_read_space?(Scope.t(), ConfluencePhxMirror.Mirror.Space.t()) :: boolean()
  def can_read_space?(%Scope{} = scope, space) do
    Scope.admin?(scope) or owns?(scope, space) or
      (not personal_space?(space) and space_allows?(scope, space.id))
  end

  @doc "Whether the reader may open a page or blog post."
  @spec can_read_page?(Scope.t(), ConfluencePhxMirror.Mirror.Page.t()) :: boolean()
  def can_read_page?(%Scope{} = scope, page) do
    Scope.admin?(scope) or
      (space_readable?(scope, page.space_id) and page_allows?(scope, page.confluence_id))
  end

  @doc """
  Whether a space is somebody's own.

  Confluence keys a personal space by its owner's account id
  (`~5F057CBE0B38B10022628D68`), and only that account — and an administrator —
  may read it. Nothing else narrows a space this completely, so the rule lives
  here rather than in the space's permissions.
  """
  @spec personal_space?(map()) :: boolean()
  def personal_space?(%{type: "personal"}), do: true
  def personal_space?(_space), do: false

  @doc """
  Every space the reader may see, by name.

  This is what the shell lists in its space switcher, so it has to agree with
  the directories — and it is one query, not one per space.

  Options:

    * `:limit` — how many to return. The switcher is a menu, not a directory:
      it takes a window and leaves "all spaces" to `/spaces`, which pages in
      the database.
    * `:query` — narrows to the spaces whose name or key matches, on the same
      rule the directory uses, so typing "LOAD01" in the switcher finds what
      the directory would.
  """
  @spec readable_spaces(Scope.t(), keyword()) :: [Space.t()]
  def readable_spaces(%Scope{} = scope, opts \\ []) do
    from(s in Space,
      as: :space,
      where: is_nil(s.deleted_at),
      order_by: [asc: s.name],
      limit: ^Keyword.get(opts, :limit)
    )
    |> Mirror.named_like(Keyword.get(opts, :query, ""))
    |> restrict_spaces(scope)
    |> Repo.all()
  end

  @doc """
  Narrows a `Space` query — built with `as: :space` — to the spaces the reader
  may see.

  `can_read_space?/2` decides one space, which is right for opening a page and
  wrong for a catalog: a directory that asked it per space would run one query
  per space. This asks once, inside the statement that filters and pages the
  catalog, so the cost does not grow with the number of spaces.

  The rule therefore exists twice — as a predicate over a synced row and as SQL
  — and the two are held to the same answer by the tests.
  """
  @spec restrict_spaces(Ecto.Queryable.t(), Scope.t()) :: Ecto.Queryable.t()
  def restrict_spaces(query, %Scope{} = scope) do
    if Scope.admin?(scope) do
      query
    else
      where(
        query,
        [s],
        (s.type != "personal" and
           (not exists(read_permissions()) or exists(read_permissions_for(scope)))) or
          (s.type == "personal" and fragment("lower(?)", s.key) == ^owner_key(scope))
      )
    end
  end

  defp read_permissions do
    from(sp in SpacePermission,
      where: sp.operation == "read" and sp.space_id == parent_as(:space).id,
      select: 1
    )
  end

  defp read_permissions_for(scope) do
    subjects = permitted_subjects(scope)

    from(sp in SpacePermission,
      where: sp.operation == "read" and sp.space_id == parent_as(:space).id,
      where: ^subjects,
      select: 1
    )
  end

  @doc """
  Narrows a `Page` query — built with `as: :page` — to the pages the reader may
  open, applying both levels of the rule inside the statement.

  A catalogue that counts rather than lists (`Catalog.labels/2` asks how many
  pages carry a label) needs the answer to be about pages the reader could
  actually read, and it needs it without loading them.
  """
  @spec restrict_pages(Ecto.Queryable.t(), Scope.t()) :: Ecto.Queryable.t()
  def restrict_pages(query, %Scope{} = scope) do
    if Scope.admin?(scope) do
      query
    else
      where(
        query,
        [p],
        ((not exists(personal_space_of_page()) and
            (not exists(page_space_permissions()) or
               exists(page_space_permissions_for(scope)))) or
           exists(own_space_of_page(scope))) and
          (not exists(page_read_restrictions()) or exists(page_read_restrictions_for(scope)))
      )
    end
  end

  defp page_space_permissions do
    from(sp in SpacePermission,
      where: sp.operation == "read" and sp.space_id == parent_as(:page).space_id,
      select: 1
    )
  end

  defp page_space_permissions_for(scope) do
    subjects = permitted_subjects(scope)

    from(sp in SpacePermission,
      where: sp.operation == "read" and sp.space_id == parent_as(:page).space_id,
      where: ^subjects,
      select: 1
    )
  end

  # A page in a personal space is its owner's, whatever permissions the space
  # carries — and a personal space usually carries none, which without these two
  # would make it the most open space in the mirror.
  defp personal_space_of_page do
    from(s in Space,
      where: s.id == parent_as(:page).space_id and s.type == "personal",
      select: 1
    )
  end

  defp own_space_of_page(scope) do
    from(s in Space,
      where:
        s.id == parent_as(:page).space_id and s.type == "personal" and
          fragment("lower(?)", s.key) == ^owner_key(scope),
      select: 1
    )
  end

  defp page_read_restrictions do
    from(r in PageRestriction,
      where: r.operation == "read" and r.page_id == parent_as(:page).id,
      select: 1
    )
  end

  defp page_read_restrictions_for(scope) do
    subjects = permitted_subjects(scope)

    from(r in PageRestriction,
      where: r.operation == "read" and r.page_id == parent_as(:page).id,
      where: ^subjects,
      select: 1
    )
  end

  # Everyone may match an anonymous permission; the rest depend on who is
  # asking. The first clause is unconditional, so the fold always has a seed.
  defp permitted_subjects(%Scope{} = scope) do
    [
      dynamic([sp], sp.subject_type == "anonymous"),
      signed_in_subject(scope),
      user_subject(scope),
      group_subject(scope)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(fn subject, acc -> dynamic(^acc or ^subject) end)
  end

  defp signed_in_subject(%Scope{} = scope) do
    if Scope.signed_in?(scope), do: dynamic([sp], sp.subject_type == "authenticated"), else: nil
  end

  defp user_subject(%Scope{user: %User{} = user}) do
    keys = user |> User.identity_keys() |> Enum.map(&String.downcase/1)

    dynamic([sp], sp.subject_type == "user" and fragment("lower(?)", sp.subject_key) in ^keys)
  end

  defp user_subject(_scope), do: nil

  # The groups the reader carries on the scope; `subject_matches?/2` decides a
  # single space from the same list, so the two stay in step.
  defp group_subject(%Scope{user: %User{} = user}) do
    case Enum.uniq(user.groups || []) do
      [] -> nil
      groups -> dynamic([sp], sp.subject_type == "group" and sp.subject_key in ^groups)
    end
  end

  defp group_subject(_scope), do: nil

  @doc """
  Narrows an already-loaded list of pages to the ones the reader may see.

  Offline cousins of `restrict_spaces/2`: a caller that has pages in hand (an
  archive, a page of search results) asks once, and the answer costs a fixed
  three queries no matter how many pages there are — the spaces' permissions,
  which of those spaces are personal, and the pages' restrictions.
  """
  @spec readable_pages(Scope.t(), [ConfluencePhxMirror.Mirror.Page.t()]) ::
          [ConfluencePhxMirror.Mirror.Page.t()]
  def readable_pages(%Scope{} = scope, pages) do
    if Scope.admin?(scope) do
      pages
    else
      space_ids = Enum.map(pages, & &1.space_id)
      spaces = space_permissions_by(space_ids)
      owners = personal_spaces_by(space_ids)
      restrictions = page_restrictions_by(Enum.map(pages, & &1.id))
      Enum.filter(pages, &visible?(scope, &1, spaces, owners, restrictions))
    end
  end

  @doc """
  Whether every reader sees the same pages.

  An administrator does, and so does everybody on a mirror with no space
  permissions, no page restrictions and no personal space — which is most of
  them. A screen that counts or lists content can then compute one answer for
  the whole mirror instead of one per reader; when this is false it has to ask
  per reader.
  """
  @spec uniform_readership?(Scope.t()) :: boolean()
  def uniform_readership?(%Scope{} = scope) do
    Scope.admin?(scope) or (not Mirror.any_permissions?() and not Mirror.any_personal_spaces?())
  end

  @doc """
  The sidebar branch for `page` (or the space's roots without one), with the
  pages the reader may not open left out.

  The filter runs inside the branch's own statement rather than over its
  result, so a title the reader may not see never leaves the database and the
  sidebar costs no extra query.
  """
  @spec branch(Scope.t(), integer(), ConfluencePhxMirror.Mirror.Page.t() | nil) ::
          %{nodes: list(), truncated?: boolean()}
  def branch(%Scope{} = scope, space_id, page \\ nil) do
    Mirror.branch_tree(space_id, page, filter: &restrict_pages(&1, scope))
  end

  @doc """
  Narrows search results (`%{page: page, snippet: _, rank: _}`) to the pages the
  reader may see.

  Search itself stays free of the permission model: it answers "what matches",
  and the caller asks this question once about the whole result set.
  """
  @spec readable_results(Scope.t(), [map()]) :: [map()]
  def readable_results(%Scope{} = scope, results) do
    if Scope.admin?(scope) do
      results
    else
      readable = readable_pages(scope, Enum.map(results, & &1.page))
      ids = MapSet.new(readable, & &1.id)
      Enum.filter(results, &MapSet.member?(ids, &1.page.id))
    end
  end

  defp visible?(scope, page, spaces, owners, restrictions) do
    space_visible?(scope, page.space_id, spaces, owners) and
      allows?(scope, Map.get(restrictions, page.id, []))
  end

  defp space_visible?(scope, space_id, spaces, owners) do
    case Map.fetch(owners, space_id) do
      {:ok, key} -> owns_key?(scope, key)
      :error -> allows?(scope, Map.get(spaces, space_id, []))
    end
  end

  @doc """
  The pages from `pages` that may be listed on `host` without telling a reader
  about content they may not open.

  Confluence resolves a macro per viewer. A static mirror resolves it once, at
  sync time, and bakes one answer into the page for everybody, so a listed page
  may only be one whose audience is at least as wide as the host's: everyone who
  may read `host` may read it too. A page restricted to a group may list open
  pages; an open page may not list a restricted one.
  """
  @spec readable_alongside(Mirror.Page.t(), [ConfluencePhxMirror.Mirror.Page.t()]) ::
          [ConfluencePhxMirror.Mirror.Page.t()]
  def readable_alongside(%Mirror.Page{} = host, pages) do
    space_ids = [host.space_id | Enum.map(pages, & &1.space_id)]
    spaces = space_permissions_by(space_ids)
    owners = personal_spaces_by(space_ids)
    restrictions = page_restrictions_by([host.id | Enum.map(pages, & &1.id)])
    host_subjects = effective_subjects(host, spaces, owners, restrictions)

    Enum.filter(pages, fn page ->
      at_least_as_wide?(effective_subjects(page, spaces, owners, restrictions), host_subjects)
    end)
  end

  # A page's own restrictions decide before its space does, and no named subject
  # means everybody may read it.
  defp effective_subjects(page, spaces, owners, restrictions) do
    case Map.get(restrictions, page.id, []) do
      [] -> space_subjects(page, spaces, owners)
      subjects -> MapSet.new(subjects, &{&1.subject_type, &1.subject_key})
    end
  end

  # A personal space's audience is its owner, and only its owner: a page in one
  # may not be listed on any page open to more people than that.
  defp space_subjects(page, spaces, owners) do
    case Map.fetch(owners, page.space_id) do
      {:ok, key} ->
        MapSet.new([{"user", owner_identity(key)}])

      :error ->
        case Map.get(spaces, page.space_id, []) do
          [] -> :everyone
          subjects -> MapSet.new(subjects, &{&1.subject_type, &1.subject_key})
        end
    end
  end

  defp at_least_as_wide?(:everyone, _host), do: true
  defp at_least_as_wide?(_contributor, :everyone), do: false
  defp at_least_as_wide?(contributor, host), do: MapSet.subset?(host, contributor)

  # No rows means open, exactly like space_allows?/2 and page_allows?/2.
  defp allows?(_scope, []), do: true
  defp allows?(scope, subjects), do: Enum.any?(subjects, &subject_matches?(scope, &1))

  defp space_permissions_by(space_ids) do
    ids = ids(space_ids)

    from(sp in SpacePermission,
      where: sp.operation == "read" and sp.space_id in ^ids,
      select: {sp.space_id, sp.subject_type, sp.subject_key}
    )
    |> Repo.all()
    |> group_subjects()
  end

  defp page_restrictions_by(page_ids) do
    ids = ids(page_ids)

    from(r in PageRestriction,
      where: r.operation == "read" and r.page_id in ^ids,
      select: {r.page_id, r.subject_type, r.subject_key}
    )
    |> Repo.all()
    |> group_subjects()
  end

  defp ids(values), do: values |> Enum.uniq() |> Enum.reject(&is_nil/1)

  defp group_subjects(rows) do
    Enum.group_by(
      rows,
      &elem(&1, 0),
      fn {_id, type, key} -> %{subject_type: type, subject_key: key} end
    )
  end

  defp space_allows?(scope, space_id) do
    case Mirror.space_permissions(space_id) do
      [] -> true
      subjects -> Enum.any?(subjects, &subject_matches?(scope, &1))
    end
  end

  # A page is readable when its space is, so the rule for personal spaces has to
  # be asked of the space the page lives in — the page itself says nothing but
  # its space's local id.
  defp space_readable?(scope, space_id) do
    case Mirror.find_space_by_id(space_id) do
      {:ok, space} -> can_read_space?(scope, space)
      {:error, :not_found} -> false
    end
  end

  # The spaces among `space_ids` that are somebody's own, by the account id
  # their key names. A space whose key is not an account id cannot be one.
  defp personal_spaces_by(space_ids) do
    ids = ids(space_ids)

    from(s in Space, where: s.id in ^ids and s.type == "personal", select: {s.id, s.key})
    |> Repo.all()
    |> Map.new()
  end

  defp owns?(scope, %{key: key}), do: owns_key?(scope, key)
  defp owns?(_scope, _space), do: false

  defp owns_key?(%Scope{user: %User{confluence_account_id: account}}, key)
       when is_binary(account) and is_binary(key) do
    String.downcase(key) == "~" <> String.downcase(account)
  end

  defp owns_key?(_scope, _key), do: false

  # The key a personal space would have for this reader, lower case like every
  # other identity comparison. A reader without a Confluence account id owns no
  # personal space, and "" matches no key.
  defp owner_key(%Scope{user: %User{confluence_account_id: account}}) when is_binary(account),
    do: "~" <> String.downcase(account)

  defp owner_key(_scope), do: ""

  # A personal space's key is `~` and its owner's account id.
  defp owner_identity(key) when is_binary(key),
    do: key |> String.trim_leading("~") |> String.downcase()

  defp page_allows?(scope, confluence_id) do
    case Mirror.page_restrictions(confluence_id) do
      [] -> true
      subjects -> Enum.any?(subjects, &subject_matches?(scope, &1))
    end
  end

  defp subject_matches?(_scope, %{subject_type: "anonymous"}), do: true
  defp subject_matches?(scope, %{subject_type: "authenticated"}), do: Scope.signed_in?(scope)

  defp subject_matches?(%Scope{user: %User{} = user}, %{subject_type: "user", subject_key: key}) do
    same_email?(user, key) or user.confluence_account_id == key
  end

  defp subject_matches?(%Scope{user: %User{} = user}, %{subject_type: "group", subject_key: key}) do
    key in (user.groups || []) or Mirror.member_of_group?(User.identity_keys(user), key)
  end

  defp subject_matches?(_scope, _subject), do: false

  defp same_email?(%User{email: email}, key) when is_binary(key) do
    String.downcase(email) == String.downcase(key)
  end

  defp same_email?(_user, _key), do: false
end
