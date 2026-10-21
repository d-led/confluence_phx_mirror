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
  Confluence account id; group names come from the reader's mirrored groups.


  The decision is a pure function of the `Scope` and the mirror's tables, which
  is what makes it cheap to call from controllers, LiveViews and the API alike.
  """

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror

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

  @doc "The subset of `spaces` the reader may see."
  def visible_spaces(%Scope{} = scope, spaces) when is_list(spaces) do
    Enum.filter(spaces, &can_read_space?(scope, &1))
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
    key in (user.groups || [])
  end

  defp subject_matches?(_scope, _subject), do: false

  defp same_email?(%User{email: email}, key) when is_binary(key) do
    String.downcase(email) == String.downcase(key)
  end

  defp same_email?(_user, _key), do: false
end
