defmodule ConfluencePhxMirror.Accounts.UserPolicy.ReadersMustExistInConfluence do
  @moduledoc """
  Only people the mirrored site knows may have an account.

  An identity provider usually serves a wider organisation than the site being
  mirrored, so "the proxy let them in" is not evidence of anything. This policy
  admits an identity only when the mirror has a reason to:

    * it administers this mirror — a role here, a seeded administrator, or
      membership of an administration group;
    * the site names it: a member of a group the sync lists, somebody named in a
      space permission or a page restriction, or the author of a page or a
      comment — whoever may read on Confluence may read here, and an author is on
      the site before any permission has listed them;
    * the identity provider asserts a group, and the site lists that person in a
      group of that name — the one claim the mirror can actually check.

  A group the site has never shown is not evidence, and neither is a group the
  site lists with somebody else in it. This is the default policy, and it is what
  `CM_PROXY_AUTH_MEMBERS_ONLY=true` used to mean.
  """

  @behaviour ConfluencePhxMirror.Accounts.UserPolicy

  alias ConfluencePhxMirror.Accounts.{Admins, User}
  alias ConfluencePhxMirror.Mirror

  @impl true
  def allows?(identity, _purpose) do
    administrator?(identity) or
      Mirror.identity_known?(keys(identity)) or
      Mirror.members_of_asserted_groups?(groups(identity), keys(identity))
  end

  # An account that administers the mirror stays able to sign in even when the
  # site does not name it: locking the last way in is not a permission decision.
  defp administrator?(identity) do
    case Map.get(identity, :user) do
      %User{} = user -> Admins.admin?(user)
      _no_account -> identity[:email] && Admins.seeded?(identity[:email])
    end
  end

  defp keys(identity) do
    case Map.get(identity, :user) do
      %User{} = user -> User.identity_keys(user)
      _no_account -> [identity[:email], identity[:account_id]]
    end
    |> Enum.reject(&is_nil/1)
  end

  defp groups(identity), do: Map.get(identity, :groups, [])
end
