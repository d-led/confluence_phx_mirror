defmodule ConfluencePhxMirror.Accounts.UserPolicy.NewUsersCanReadPublicSpaces do
  @moduledoc """
  Anybody who arrives may have an account.

  This is the policy for a mirror whose audience is wider than the site's
  contributors — a whole organisation, a published handbook's readers, a
  customer base — and whose public content is meant to be read by all of them.
  It admits everyone and restricts nothing: what a reader can open is still
  decided by the space permissions and page restrictions the sync mirrored, so
  a reader admitted here sees the public spaces and none of the restricted ones.

  It is also what `CM_PROXY_AUTH_MEMBERS_ONLY=false` and `self_signup` used to
  mean, per door. The difference is that it now says so in one place.
  """

  @behaviour ConfluencePhxMirror.Accounts.UserPolicy

  @impl true
  def allows?(_identity, _purpose), do: true
end
