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
  alias ConfluencePhxMirror.Mirror.{Space, SpacePermission}
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
  """
  @spec readable_spaces(Scope.t()) :: [Space.t()]
  def readable_spaces(%Scope{} = scope) do
    from(s in Space, as: :space, order_by: [asc: s.name])
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
