defmodule ConfluencePhxMirror.Accounts.Scope do
  @moduledoc """
  The Phoenix 1.8 scope: the authenticated context a request or LiveView runs in.

  Keeping a scope (instead of passing a user around) gives the UI and the
  contexts one stable object to ask authorisation questions of, and leaves room
  for future per-space scopes without changing every call site.
  """

  alias ConfluencePhxMirror.Accounts.{Admins, User}

  defstruct user: nil

  @type t :: %__MODULE__{user: User.t() | nil}

  def for_user(nil), do: %__MODULE__{}
  def for_user(%User{} = user), do: %__MODULE__{user: user}

  def user(%__MODULE__{user: user}), do: user

  def admin?(%__MODULE__{user: %User{} = user}), do: Admins.admin?(user)
  def admin?(%__MODULE__{}), do: false

  def signed_in?(%__MODULE__{user: %User{}}), do: true
  def signed_in?(%__MODULE__{}), do: false
end
