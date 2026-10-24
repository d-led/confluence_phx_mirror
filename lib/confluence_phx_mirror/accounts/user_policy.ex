defmodule ConfluencePhxMirror.Accounts.UserPolicy do
  @moduledoc """
  Who counts as a reader of this mirror.

  The people who write in Confluence and the people who read the mirror are not
  the same audience — readers can be far more numerous, and often belong to a
  different system altogether (an organisation's identity provider, a customer
  portal, a partner). So "may this arriving identity have an account here?" is a
  question of its own, and it is kept out of the proxy, out of the sign-in form
  and out of `ConfluencePhxMirror.Authorization`:

    * a `UserPolicy` answers it, one identity at a time;
    * `Authorization` answers the other question — what an admitted reader may
      see — by replaying the permissions the sync mirrored.

  The two are deliberately separate. A policy that admits everybody therefore
  admits them to *public* spaces only, because a space whose read permissions
  the sync mirrored still names its readers.

  ## What ships

    * `UserPolicy.NewUsersCanReadPublicSpaces` — anyone who arrives gets an
      account; the mirrored permissions decide what they can open.
    * `UserPolicy.ReadersMustExistInConfluence` — only identities the mirrored
      site names: a person in a group the site lists, somebody named in a space
      permission or page restriction, a member of a group the identity provider
      asserts *and* the site lists, or a mirror administrator.

  ## Choosing one

  `CM_USER_POLICY` names it: `new_users_can_read_public_spaces` (alias
  `allow_all`) or `readers_must_exist_in_confluence` (alias `members_only`).

  A deployment that names none keeps the rule its older switches imply, because
  those switches were the same question asked per transport:

    * the proxy path admits site members unless `CM_PROXY_AUTH_MEMBERS_ONLY` was
      switched off;
    * the sign-in path admits new addresses only with `self_signup` on.

  Naming a policy replaces both: one deployment, one answer.

  ## Combining

  `:user_policy` may also be `{:any_of, [a, b]}` or `{:all_of, [a, b]}`, because
  the honest answer is often "an administrator, or anybody on the allow-list an
  operator maintains here, or anybody the site names". Policies compose without
  knowing about each other.

  ## Stateful policies

  A policy is asked once per arriving identity and answers `true` or `false`. A
  policy that needs to look something up (an allow-list table an operator edits,
  a cached membership lookup, a call to an identity provider) owns that lookup:
  keep it in the mirror's tables or behind a process the policy owns, not in the
  plug, which runs on every request.
  """

  alias ConfluencePhxMirror.Accounts.User

  alias ConfluencePhxMirror.Accounts.UserPolicy.{
    NewUsersCanReadPublicSpaces,
    ReadersMustExistInConfluence
  }

  @typedoc """
  An identity that wants in.

  `:user` is the account the mirror already has for it, when it has one — that is
  how a policy sees a role, a group-granted administration or a ban. `:groups`
  are group names an identity provider asserted; the mirror can check them
  against what the site says, and nothing else.
  """
  @type identity :: %{
          required(:email) => String.t() | nil,
          optional(:account_id) => String.t() | nil,
          optional(:display_name) => String.t() | nil,
          optional(:groups) => [String.t()],
          optional(:user) => User.t() | nil
        }

  @typedoc "Which door the identity is at, for the defaults that predate policies."
  @type purpose :: :proxy | :sign_in

  @type policy ::
          module()
          | {:any_of, [policy()]}
          | {:all_of, [policy()]}

  @doc """
  Whether this identity may have an account, asked at `purpose`'s door.

  A boolean on purpose: an atom like `:deny` is truthy, and one `if` that reads
  `if seeded? or policy.allows?(…)` would then admit everybody.
  """
  @callback allows?(identity(), purpose()) :: boolean()

  @doc "The policy this deployment uses."
  @spec policy(purpose()) :: policy()
  def policy(purpose \\ :sign_in) do
    case Application.get_env(:confluence_phx_mirror, :user_policy) do
      nil -> implied(purpose)
      configured -> configured
    end
  end

  @doc """
  The policy a configured name stands for.

  `CM_USER_POLICY` is read by hand, so an unknown name raises rather than
  falling back to a default: a typo must not quietly widen or narrow the
  audience.
  """
  @spec named!(String.t()) :: module()
  def named!(name) do
    case name |> to_string() |> String.trim() |> String.downcase() do
      "new_users_can_read_public_spaces" -> NewUsersCanReadPublicSpaces
      "allow_all" -> NewUsersCanReadPublicSpaces
      "readers_must_exist_in_confluence" -> ReadersMustExistInConfluence
      "members_only" -> ReadersMustExistInConfluence
      other -> raise ArgumentError, "unknown user policy #{inspect(other)}"
    end
  end

  @doc "A sentence an operator can read, for the screens and the logs."
  @spec describe(policy()) :: String.t()
  def describe(NewUsersCanReadPublicSpaces), do: "anybody may read the public spaces"
  def describe(ReadersMustExistInConfluence), do: "readers must exist in Confluence"

  def describe({:any_of, policies}),
    do: "any of: " <> Enum.map_join(policies, " or ", &describe/1)

  def describe({:all_of, policies}),
    do: "all of: " <> Enum.map_join(policies, " and ", &describe/1)

  def describe(module) when is_atom(module), do: module |> Module.split() |> List.last()

  @doc """
  Whether an identity may have an account here.

      iex> UserPolicy.allows?(%{email: "someone@example.com"}, :proxy)
      false
  """
  @spec allows?(identity(), purpose()) :: boolean()
  def allows?(identity, purpose), do: decide(policy(purpose), identity, purpose)

  @doc """
  The policy the pre-policy switches imply, per door.

  `CM_PROXY_AUTH_MEMBERS_ONLY=false` and `self_signup` were the same question
  asked from two places; they keep their meaning until a deployment names a
  policy of its own.
  """
  @spec implied(purpose()) :: policy()
  def implied(:proxy) do
    if config(:proxy_auth_members_only, true),
      do: ReadersMustExistInConfluence,
      else: NewUsersCanReadPublicSpaces
  end

  def implied(:sign_in) do
    if config(:self_signup, false),
      do: NewUsersCanReadPublicSpaces,
      else: ReadersMustExistInConfluence
  end

  defp decide({:any_of, policies}, identity, purpose) do
    Enum.any?(policies, &decide(&1, identity, purpose))
  end

  defp decide({:all_of, policies}, identity, purpose) do
    Enum.all?(policies, &decide(&1, identity, purpose))
  end

  defp decide(module, identity, purpose) when is_atom(module) do
    module.allows?(identity, purpose)
  end

  defp config(key, default), do: Application.get_env(:confluence_phx_mirror, key, default)
end
