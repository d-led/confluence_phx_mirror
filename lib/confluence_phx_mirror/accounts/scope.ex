defmodule ConfluencePhxMirror.Accounts.Scope do
  @moduledoc """
  The Phoenix 1.8 scope: the authenticated context a request or LiveView runs in.

  Keeping a scope (instead of passing a user around) gives the UI and the
  contexts one stable object to ask authorisation questions of, and leaves room
  for future per-space scopes without changing every call site.

  Whether the reader administers the mirror is decided once, when the scope is
  built: it consults the config, the account's role and the membership of the
  synced admin groups, and the last of those is a query. One page asks the
  question from the layout, the controller, the catalog and every predicate it
  passes through, so answering it per call would turn one page into several
  identical lookups.
  """

  alias ConfluencePhxMirror.Accounts.{Admins, User}

  defstruct user: nil, admin?: false

  @type t :: %__MODULE__{user: User.t() | nil, admin?: boolean()}

  def for_user(nil), do: %__MODULE__{}
  def for_user(%User{} = user), do: %__MODULE__{user: user, admin?: Admins.admin?(user)}

  def user(%__MODULE__{user: user}), do: user

  def admin?(%__MODULE__{admin?: admin?}), do: admin?

  @doc """
  The scope a request or socket already carries, or a fresh one for its user.

  Controllers and LiveViews ask for the scope through this rather than building
  one: the pipeline resolved the reader once, including whether they administer
  the mirror, and rebuilding it per call site asks the database again.
  """
  def from_assigns(assigns) when is_map(assigns) do
    case assigns do
      %{current_scope: %__MODULE__{} = scope} -> scope
      %{current_user: user} -> for_user(user)
      _no_identity -> for_user(nil)
    end
  end

  def signed_in?(%__MODULE__{user: %User{}}), do: true
  def signed_in?(%__MODULE__{}), do: false
end
