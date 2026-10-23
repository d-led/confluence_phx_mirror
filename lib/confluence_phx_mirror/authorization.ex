defmodule ConfluencePhxMirror.Authorization do
  @moduledoc """
  Who may read what, replayed from what the sync learned from Confluence.

  Two levels, in Confluence's own precedence:

    1. a page with read restrictions is readable only by the listed users and
       groups;
    2. otherwise the space's read permissions decide;
    3. a space without synced permissions is open — the mirror already shows
       only what the sync account can read, and there is nothing else to go on.

  Mirror administrators always see everything. Identity is matched on e-mail or
  Confluence account id; groups come from the membership the sync reads from
  Confluence (plus any group an administrator granted here).


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
    Scope.admin?(scope) or space_allows?(scope, space.id)
  end

  @doc "Whether the reader may open a page or blog post."
  @spec can_read_page?(Scope.t(), ConfluencePhxMirror.Mirror.Page.t()) :: boolean()
  def can_read_page?(%Scope{} = scope, page) do
    Scope.admin?(scope) or
      (space_allows?(scope, page.space_id) and page_allows?(scope, page.confluence_id))
  end

  @doc """
  Every space the reader may see, by name.

  This is what the shell lists in its space switcher, so it has to agree with
  the directories — and it is one query, not one per space.

  Options:

    * `:limit` — how many to return. The switcher is a menu, not a directory:
      it takes a window and leaves "all spaces" to `/spaces`, which pages in
      the database.
  """
  @spec readable_spaces(Scope.t(), keyword()) :: [Space.t()]
  def readable_spaces(%Scope{} = scope, opts \\ []) do
    from(s in Space, as: :space, order_by: [asc: s.name], limit: ^Keyword.get(opts, :limit))
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
        not exists(read_permissions()) or exists(read_permissions_for(scope))
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
        (not exists(page_space_permissions()) or exists(page_space_permissions_for(scope))) and
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
  archive, a page of search results) asks once, and the answer costs two
  queries no matter how many pages there are — one for the spaces' permissions
  and one for the pages' restrictions.
  """
  @spec readable_pages(Scope.t(), [ConfluencePhxMirror.Mirror.Page.t()]) ::
          [ConfluencePhxMirror.Mirror.Page.t()]
  def readable_pages(%Scope{} = scope, pages) do
    if Scope.admin?(scope) do
      pages
    else
      spaces = space_permissions_by(Enum.map(pages, & &1.space_id))
      restrictions = page_restrictions_by(Enum.map(pages, & &1.id))
      Enum.filter(pages, &visible?(scope, &1, spaces, restrictions))
    end
  end

  @doc """
  Whether every reader sees the same pages.

  An administrator does, and so does everybody on a mirror with no space
  permissions and no page restrictions — which is most of them. A screen that
  counts or lists content can then compute one answer for the whole mirror
  instead of one per reader; when this is false it has to ask per reader.
  """
  @spec uniform_readership?(Scope.t()) :: boolean()
  def uniform_readership?(%Scope{} = scope) do
    Scope.admin?(scope) or not Mirror.any_permissions?()
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

  defp visible?(scope, page, spaces, restrictions) do
    allows?(scope, Map.get(spaces, page.space_id, [])) and
      allows?(scope, Map.get(restrictions, page.id, []))
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
    spaces = space_permissions_by([host.space_id | Enum.map(pages, & &1.space_id)])
    restrictions = page_restrictions_by([host.id | Enum.map(pages, & &1.id)])
    host_subjects = effective_subjects(host, spaces, restrictions)

    Enum.filter(pages, fn page ->
      at_least_as_wide?(effective_subjects(page, spaces, restrictions), host_subjects)
    end)
  end

  # A page's own restrictions decide before its space does, and no named subject
  # means everybody may read it.
  defp effective_subjects(page, spaces, restrictions) do
    case Map.get(restrictions, page.id, []) do
      [] -> space_subjects(page, spaces)
      subjects -> MapSet.new(subjects, &{&1.subject_type, &1.subject_key})
    end
  end

  defp space_subjects(page, spaces) do
    case Map.get(spaces, page.space_id, []) do
      [] -> :everyone
      subjects -> MapSet.new(subjects, &{&1.subject_type, &1.subject_key})
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
