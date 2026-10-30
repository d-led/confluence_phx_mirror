defmodule ConfluencePhxMirror.Accounts do
  @moduledoc """
  Mirror-local reader accounts.

  There are no Confluence logins: readers sign in through a single-use magic
  link, or use an API token. In development and test an administrator is
  assumed (`MIRROR_AUTO_ADMIN`), so no login is needed at all.

  An account stands for one person, and a person may hold several Confluence
  identities — the one the sign-in matched, plus any further identity an
  administrator linked. What the account may open is the union of them, which is
  why the permission checks ask `User.identity_keys/1` rather than read the
  single column.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Accounts.{Admins, ApiToken, LoginToken, TokenHash, User, UserPolicy}
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Mailer
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.GroupMember
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Settings

  @doc "Minutes a magic link stays valid."
  def login_token_minutes, do: Settings.login_token_minutes()

  @api_token_bytes 32
  # How much of a token is stored in clear as the lookup key. Twelve base64
  # characters are 72 bits: enough that two tokens of one mirror do not share a
  # prefix, and no use to anybody holding only the row.
  @token_prefix_length 12

  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.one(
      from u in User,
        where: fragment("lower(?) = ?", u.email, ^String.downcase(String.trim(email)))
    )
  end

  @doc """
  Accounts, filtered by `query` (an e-mail, a name, a group) and paged.

  The mirror can hold a hundred thousand of them, so `:limit` and `:offset`
  page in the database and the screen draws one page.
  """
  def list_users(query \\ nil, opts \\ []) do
    from(u in User, order_by: [asc: u.email])
    |> filter_users(query)
    |> limit_if(Keyword.get(opts, :limit))
    |> offset(^(Keyword.get(opts, :offset) || 0))
    |> Repo.all()
  end

  @doc "How many accounts match `query`, for the screen's \"of N\"."
  def count_users(query \\ nil) do
    from(u in User)
    |> filter_users(query)
    |> select(count())
    |> Repo.one()
  end

  @doc """
  Which of `account_ids` have an account here, and which account.

  Asked for one page of people, not for the whole site: a mirror with a hundred
  thousand identities must not read every account to decide a badge. The answer
  is a map from the identity to the account that stands for it — the identity
  the account signed in with and the ones an administrator linked alike,
  because to the permission rules they are the same person.

  Rows rather than e-mails: a badge needs only the address, but the identities
  screen and its API have to *act* on the account — link the identity or take
  it away — and an e-mail cannot be acted on.
  """
  def users_by_identity(account_ids) do
    keys = Enum.reject(account_ids, &is_nil/1)

    if keys == [] do
      %{}
    else
      from(u in User,
        where:
          u.confluence_account_id in ^keys or
            fragment("? && ?", u.identity_account_ids, ^keys)
      )
      |> Repo.all()
      |> Enum.flat_map(fn user ->
        [user.confluence_account_id | user.identity_account_ids || []]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&{&1, user})
      end)
      |> Map.new()
    end
  end

  defp limit_if(query, nil), do: query
  defp limit_if(query, limit), do: limit(query, ^limit)

  defp filter_users(query, blank) when blank in [nil, ""], do: query

  defp filter_users(query, text) do
    pattern = "%" <> (text |> to_string() |> String.trim() |> String.downcase()) <> "%"

    where(
      query,
      [u],
      fragment("lower(?) like ?", u.email, ^pattern) or
        fragment("lower(coalesce(?, '')) like ?", u.display_name, ^pattern)
    )
  end

  @doc """
  Switches an account off (or back on) on this mirror, and records who did it.

  Two administrators cannot be switched off: a protected one (seeded, or the
  bootstrap account), and the last one. Either would leave nobody able to open
  the admin screens — the same reason `change_role/3` refuses to demote them.
  """
  def set_disabled(%User{} = user, disabled?, actor) when is_boolean(disabled?) do
    cond do
      disabled? and Admins.protected?(user) ->
        {:error, :protected_admin}

      disabled? and last_admin?(user) ->
        {:error, :last_admin}

      User.disabled_here?(user) == disabled? ->
        {:ok, user}

      true ->
        with {:ok, updated} <- put_flags(user, %{disabled_at: if(disabled?, do: now())}) do
          Audit.log(actor, disabled_event(updated, disabled?))
          {:ok, updated}
        end
    end
  end

  defp disabled_event(user, true), do: User.audit_event_disabled(user)
  defp disabled_event(user, false), do: User.audit_event_enabled(user)

  @doc """
  Applies what the mirrored site says about one Atlassian account: every mirror
  account that belongs to it takes the site's state — `:active`, `:disabled`
  (the site switched them off) or `:deleted` (the site no longer has them).

  When the site is the first to name someone — an author, a group member — and
  the site will share an e-mail, the person gets an account here, because the
  mirror's own list is the only place an administrator can see them or prepare a
  ban. An identity the site keeps private (no e-mail) is not invented: there is
  nothing to sign in with and nothing to match a reader against.

  Only transitions are written and audited — a sync that runs every hour must
  not fill the log with "still active". Returns how many accounts changed.
  """
  @spec reconcile_site_status(
          String.t() | nil,
          String.t() | nil,
          :active | :disabled | :deleted,
          keyword()
        ) ::
          non_neg_integer()
  def reconcile_site_status(account_id, email, state, opts \\ [])
      when state in [:active, :disabled, :deleted] do
    accounts =
      case site_accounts(account_id, email) do
        [] -> provision_site_person(account_id, email, state, opts)
        existing -> existing
      end

    Enum.count(accounts, &mirror_site_state(&1, state))
  end

  defp provision_site_person(_account_id, _email, :deleted, _opts), do: []
  defp provision_site_person(_account_id, email, _state, _opts) when email in [nil, ""], do: []

  defp provision_site_person(account_id, email, _state, opts) do
    changeset =
      %User{}
      |> User.changeset(%{
        email: email,
        display_name: Keyword.get(opts, :display_name) || display_name_for(email)
      })
      |> User.identity_changeset(%{confluence_account_id: account_id})
      |> Ecto.Changeset.put_change(:provisioned_at, now())

    # `on_conflict: :nothing` because a sign-in may have inserted the same
    # address a moment earlier; whoever won, the row is the person the site
    # named. An address the schema rejects cannot sign in either, so it is not
    # turned into an account.
    case Repo.insert(changeset, on_conflict: :nothing) do
      {:ok, %User{id: nil}} -> site_accounts(account_id, email)
      {:ok, user} -> audit_created(user)
      {:error, _rejected} -> []
    end
  end

  defp audit_created(user) do
    Audit.log(Audit.system_actor(), User.audit_event_created(user))
    [user]
  end

  defp site_accounts(account_id, email) do
    keys = Enum.reject([account_id, email && User.normalise_email(email)], &is_nil/1)

    from(u in User,
      where:
        coalesce(u.confluence_account_id, "") in ^keys or
          fragment("lower(?)", u.email) in ^keys
    )
    |> Repo.all()
  end

  defp mirror_site_state(user, state) do
    if site_state(user) == state do
      false
    else
      {:ok, updated} = put_flags(user, site_flags(state))
      Audit.log(Audit.system_actor(), User.audit_event_for_site_state(updated, state))
      true
    end
  end

  defp site_state(%User{} = user) do
    cond do
      User.deleted_on_site?(user) -> :deleted
      User.disabled_on_site?(user) -> :disabled
      true -> :active
    end
  end

  # Being gone from the site outranks being switched off there: a deleted
  # account is not a deactivated one, and the difference decides whether the
  # deployment may let it read.
  defp site_flags(:active), do: %{site_disabled_at: nil, site_deleted_at: nil}
  defp site_flags(:disabled), do: %{site_disabled_at: now(), site_deleted_at: nil}
  defp site_flags(:deleted), do: %{site_disabled_at: nil, site_deleted_at: now()}

  defp put_flags(user, attrs) do
    user |> Ecto.Changeset.change(attrs) |> Repo.update()
  end

  @doc "The Atlassian account ids the mirror's own accounts are known by."
  def account_ids do
    from(u in User,
      where: not is_nil(u.confluence_account_id),
      distinct: true,
      select: u.confluence_account_id
    )
    |> Repo.all()
  end

  @doc """
  Finds a user or creates one (used by magic-link sign-up and auto admin).

  Two requests for the same *new* address can arrive together — a proxy that
  authenticates every request makes that a question of load, not of luck — and
  both would read "no such user" and insert. So the insert is allowed to lose:
  the one that collides inserts nothing, and the row it collided with is read
  back. When the other transaction has not committed yet even that read comes
  back empty, and the answer is `{:error, :racing}` rather than a changeset the
  caller cannot act on; the next request finds the row.

  Only a real insert logs `user.created`: the row that was already there is
  somebody else's news.
  """
  @spec ensure_user(String.t(), map()) ::
          {:ok, User.t()} | {:error, :racing} | {:error, Ecto.Changeset.t()}
  def ensure_user(email, attrs \\ %{}) do
    case get_user_by_email(email) do
      nil ->
        insert_user(email, attrs)

      user ->
        {:ok, user}
    end
  end

  defp insert_user(email, attrs) do
    %User{}
    |> User.changeset(Map.merge(%{email: email, display_name: display_name_for(email)}, attrs))
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, %User{id: id} = user} when not is_nil(id) ->
        Audit.log(Audit.system_actor(), User.audit_event_created(user))
        {:ok, user}

      # The insert did nothing because the address is taken, and the database
      # will not say which row took it: that is the read below.
      {:ok, _nothing_inserted} ->
        re_read(email)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp re_read(email) do
    case get_user_by_email(email) do
      nil -> {:error, :racing}
      user -> {:ok, user}
    end
  end

  def ensure_user!(email, attrs \\ %{}) do
    case ensure_user(email, attrs) do
      {:ok, user} ->
        user

      {:error, %Ecto.Changeset{} = changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset

      {:error, reason} ->
        raise "could not ensure an account for #{email}: #{inspect(reason)}"
    end
  end

  @doc """
  Records that a reader arrived: stamps the account and writes the log entry.

  A visit, not a request. The proxy plug calls this when a session does not
  already carry the same reader; a magic link calls it when a token is consumed.
  Without it, a deployment behind a proxy has accounts whose "last seen" column
  says never and a log that cannot answer "did that person ever come in?" —
  which reads exactly like an account that was never created.
  """
  @spec record_sign_in(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def record_sign_in(%User{} = user, method \\ "magic_link") do
    with {:ok, user} <-
           user |> Ecto.Changeset.change(last_sign_in_at: now()) |> Repo.update() do
      Audit.log({:user, user}, User.audit_event_signed_in(user, method))
      {:ok, user}
    end
  end

  @doc "Creates a user explicitly (admin UI)."
  def create_user(attrs, actor) do
    with {:ok, user} <-
           %User{}
           |> User.changeset(attrs)
           |> Repo.insert() do
      Audit.log(actor, User.audit_event_created(user))
      {:ok, user}
    end
  end

  @doc """
  Tells the person that the account an administrator made for them exists.

  `{:ok, :not_configured}` when nothing would actually leave the node: mail
  switched off, or no relay and Swoosh's Local adapter, which writes a file. A
  screen that said "a welcome was sent" in that state would be lying about the
  one thing the administrator cannot see. `{:ok, :over_budget}` is the same kind
  of honesty: the provider's day is spent (`Mail.Budget`), so this message waits
  rather than being refused by the relay.

  No sign-in link is included on purpose: whether a link or a company account
  signs a reader in is the deployment's business (proxy, magic link), and a
  link minted here would be the wrong one for half of them. The mail points at
  the mirror; the reader signs in the way they already do.
  """
  @spec welcome(User.t(), ConfluencePhxMirror.Audit.actor()) ::
          {:ok, :sent} | {:ok, :not_configured} | {:ok, :over_budget} | {:error, term()}
  def welcome(%User{} = user, actor \\ ConfluencePhxMirror.Audit.system_actor()) do
    if mail_configured?() do
      user
      |> ConfluencePhxMirror.Accounts.Emails.welcome(
        site: ConfluencePhxMirror.Sites.name(),
        url: ConfluencePhxMirror.Sites.url()
      )
      |> ConfluencePhxMirror.Mailer.send(
        ConfluencePhxMirror.Mail.Budget.key(:welcome, user),
        actor
      )
      |> case do
        {:ok, _} -> {:ok, :sent}
        {:error, :spent, _seconds} -> {:ok, :over_budget}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :not_configured}
    end
  end

  # `Local` is Swoosh's "write it to a file" adapter, so a deployment that has
  # configured neither the mail server nor a relay sends nothing.
  defp mail_configured? do
    ConfluencePhxMirror.Settings.notifications_enabled?() and
      Application.get_env(:confluence_phx_mirror, Mailer, [])[:adapter] != Swoosh.Adapters.Local
  end

  @doc """
  Changes the role of an account.

  Seeded administrators (`CM_ADMINS`) and the local bootstrap account keep
  their administration: demoting them would remove the only way back in. So
  does the last administrator, whoever they are.
  """
  def change_role(%User{} = user, role, actor) do
    previous = user.role

    cond do
      role != "admin" and Admins.protected?(user) ->
        {:error, :protected_admin}

      loses_administration?(user, role) ->
        {:error, :last_admin}

      true ->
        with {:ok, user} <- user |> User.changeset(%{role: role}) |> Repo.update() do
          Audit.log(actor, User.audit_event_role_changed(user, previous))
          {:ok, user}
        end
    end
  end

  # A last administrator may still be demoted when the role is not the only
  # thing that makes them one — `CM_ADMINS` and an admin group do not care about
  # the role, so the account would keep its way in.
  defp loses_administration?(%User{} = user, role) do
    last_admin?(user) and not Admins.admin?(%User{user | role: role})
  end

  @doc """
  Whether this account is the mirror's last administrator.

  The guard against locking everybody out: switching this account off, or
  taking the `admin` role away, would leave nobody able to administer the
  mirror. Two things still count as a way in — another enabled account that
  administers the mirror, and a seeded address (`CM_ADMINS`) that is not
  switched off, which becomes an administrator the first time it signs in.
  """
  @spec last_admin?(User.t() | nil) :: boolean()
  def last_admin?(nil), do: false

  def last_admin?(%User{} = user) do
    Admins.admin?(user) and not another_administrator?(user)
  end

  defp another_administrator?(%User{} = user) do
    other_seed?(user) or other_role_admin?(user) or other_group_admin?(user)
  end

  defp other_seed?(%User{email: email}) do
    email = User.normalise_email(email)

    Admins.admins()
    |> Enum.reject(&(&1 == email))
    |> Enum.any?(&seed_can_sign_in?/1)
  end

  defp seed_can_sign_in?(email) do
    case get_user_by_email(email) do
      nil -> true
      account -> not User.disabled?(account)
    end
  end

  defp other_role_admin?(%User{} = user) do
    from(u in enabled_accounts(), where: u.id != ^user.id and u.role == "admin", select: 1)
    |> Repo.exists?()
  end

  # A member of an admin group administers the mirror whether or not they have
  # an account here: the site's membership is what decides, and they get an
  # account the first time they sign in.
  defp other_group_admin?(%User{} = user) do
    Admins.admin_groups()
    |> Enum.flat_map(&Mirror.group_members/1)
    |> Enum.reject(&(&1.subject_key in User.identity_keys(user)))
    |> Enum.any?(&member_can_sign_in?/1)
  end

  defp member_can_sign_in?(%GroupMember{} = member) do
    case account_of(member) do
      nil -> true
      account -> not User.disabled?(account)
    end
  end

  defp account_of(%GroupMember{email: email, account_id: account_id}) do
    account_by_email(email) || account_by_confluence_id(account_id)
  end

  defp account_by_email(email) when is_binary(email) and email != "",
    do: get_user_by_email(email)

  defp account_by_email(_email), do: nil

  defp account_by_confluence_id(account_id) when is_binary(account_id) and account_id != "",
    do: Repo.get_by(User, confluence_account_id: account_id)

  defp account_by_confluence_id(_account_id), do: nil

  defp enabled_accounts do
    from(u in User,
      where: is_nil(u.disabled_at) and is_nil(u.site_disabled_at) and is_nil(u.banned_at)
    )
  end

  @doc """
  Bans an account from this mirror.

  A ban is not a switch-off: it outranks every other flag, a sync never clears
  it, and it blocks deletion — deleting the row would let the next sign-in
  provision a fresh account, which is exactly what a ban is for.

  Being the harsher of the two, it refuses what switching off refuses: a seeded
  administrator, and the last administrator. Banning either is the one way to
  lock the mirror out for good, because no sync and no sign-in undoes a ban.
  """
  def ban(%User{} = user, actor) do
    if User.banned?(user) do
      {:ok, user}
    else
      with nil <- ban_blocked(user),
           {:ok, banned} <- put_flags(user, %{banned_at: now()}) do
        Audit.log(actor, User.audit_event_banned(banned))
        {:ok, banned}
      else
        blocked -> blocked
      end
    end
  end

  @doc """
  Why banning this account would be refused, or `nil` when it may be banned.

  The screen asks this before it draws the button and `ban/2` asks it before it
  writes, so there is one rule rather than two that can drift apart. Driving
  the screen off `guard` instead is what offered a Ban button for the one
  account a ban would lock the mirror out of.
  """
  @spec ban_blocked(User.t()) :: {:error, :protected_admin | :last_admin} | nil
  def ban_blocked(%User{} = user) do
    cond do
      Admins.protected?(user) -> {:error, :protected_admin}
      last_admin?(user) -> {:error, :last_admin}
      true -> nil
    end
  end

  @doc "Lifts a ban. Access follows the other flags again."
  def unban(%User{} = user, actor) do
    if User.banned?(user) do
      with {:ok, unbanned} <- put_flags(user, %{banned_at: nil}) do
        Audit.log(actor, User.audit_event_unbanned(unbanned))
        {:ok, unbanned}
      end
    else
      {:ok, user}
    end
  end

  @doc """
  Deletes an account and everything that hangs off it — tokens, subscriptions,
  login tokens.

  Refused for a banned account, because the ban has to outlive the row, for a
  protected administrator, because a deployment always has to have a way in,
  and for the last administrator, because the mirror must keep one.
  """
  def delete_user(%User{} = user, actor) do
    case deletion_blocked(user) do
      nil ->
        Audit.log(actor, User.audit_event_deleted(user))
        Repo.delete(user)

      blocked ->
        blocked
    end
  end

  @doc """
  Why deleting this account would be refused, or `nil` when it may go.

  As with `ban_blocked/1`: one rule, asked by `delete_user/2` and by the screen
  that draws the button, so the button cannot promise what the event refuses.

  A protected administrator (seeded, or the bootstrap account) is refused before
  anything else is considered. Being the last administrator is not the reason:
  deleting a seeded administrator who happens to have company would take away an
  account the deployment states must exist, and the next boot seeds it again —
  so the row would come back as a stranger with no claim to what it used to own.
  """
  @spec deletion_blocked(User.t()) :: {:error, :banned | :protected_admin | :last_admin} | nil
  def deletion_blocked(%User{} = user) do
    cond do
      Admins.protected?(user) -> {:error, :protected_admin}
      User.banned?(user) -> {:error, :banned}
      last_admin?(user) -> {:error, :last_admin}
      true -> nil
    end
  end

  @doc """
  Sets the Confluence groups a reader belongs to.

  Group membership is what grants space access and, for the configured admin
  groups, administration.
  """
  def update_groups(%User{} = user, groups, actor) when is_list(groups) do
    previous = user.groups || []

    groups =
      groups
      |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    with {:ok, user} <- user |> User.identity_changeset(%{groups: groups}) |> Repo.update() do
      Audit.log(actor, User.audit_event_groups_changed(user, previous))
      {:ok, user}
    end
  end

  @doc """
  The accounts a Confluence identity is linked to, if any.

  A mirror account stands for one person; a person can hold two Confluence
  identities. One identity belongs to one account — two accounts claiming the
  same identity would be two readers sharing every permission it carries — so
  linking asks this first.
  """
  def accounts_linked_to(account_id) when is_binary(account_id) do
    from(u in User,
      where:
        u.confluence_account_id == ^account_id or
          fragment("? && ?", u.identity_account_ids, ^[account_id]),
      order_by: [asc: u.email]
    )
    |> Repo.all()
  end

  @doc """
  Links a Confluence identity to an account: this Atlassian account is this
  person.

  What the identity carries — its group memberships, its page restrictions, the
  content it authors — becomes this account's, because `User.identity_keys/1`
  answers with every linked identity. Two things are refused: an identity the
  mirror has never seen (a typo would otherwise be a grant that silently does
  nothing), and an identity another account already holds.

  The identity the account signs in with is not touched; this is the *further*
  identities a person holds.

  Only an administrator may link, and the rule is enforced here rather than by
  the screen that happens to call it: `{:error, :not_authorized}` otherwise. A
  caller with no reader behind it — a mix task, the sync — is refused too, so an
  API or MCP surface has to pass the reader it acts for and inherit the same
  answer.
  """
  def link_identity(%User{} = user, account_id, actor) when is_binary(account_id) do
    with :ok <- authorize_linking(actor) do
      do_link_identity(user, String.trim(account_id), actor)
    end
  end

  defp do_link_identity(%User{} = user, account_id, actor) do
    linked = user.identity_account_ids || []

    cond do
      account_id == "" ->
        {:error, :blank}

      account_id in linked or account_id == user.confluence_account_id ->
        {:error, :already_linked}

      other = Enum.find(accounts_linked_to(account_id), &(&1.id != user.id)) ->
        {:error, {:linked_elsewhere, other}}

      not Mirror.identity_known?([account_id]) ->
        {:error, :unknown_identity}

      true ->
        with {:ok, user} <-
               user
               |> User.identity_changeset(%{identity_account_ids: [account_id | linked]})
               |> Repo.update() do
          Audit.log(actor, User.audit_event_identity_linked(user, account_id))
          {:ok, user}
        end
    end
  end

  @doc """
  Unlinks a Confluence identity: what it carries is no longer this account's.

  Authorized like linking — an administrator, or nobody.
  """
  def unlink_identity(%User{} = user, account_id, actor) when is_binary(account_id) do
    with :ok <- authorize_linking(actor) do
      do_unlink_identity(user, account_id, actor)
    end
  end

  defp do_unlink_identity(%User{} = user, account_id, actor) do
    linked = user.identity_account_ids || []

    if account_id in linked do
      with {:ok, user} <-
             user
             |> User.identity_changeset(%{identity_account_ids: linked -- [account_id]})
             |> Repo.update() do
        Audit.log(actor, User.audit_event_identity_unlinked(user, account_id))
        {:ok, user}
      end
    else
      {:error, :not_linked}
    end
  end

  # Linking is an access decision, so it asks the question administration asks.
  defp authorize_linking({:user, %User{} = actor}) do
    if Admins.admin?(actor), do: :ok, else: {:error, :not_authorized}
  end

  defp authorize_linking(_actor), do: {:error, :not_authorized}

  @doc "The administrator assumed in development and test."
  def ensure_admin!(email \\ admin_email()) do
    user = ensure_user!(email, %{role: "admin"})

    result =
      if user.role == "admin" do
        {:ok, user}
      else
        change_role(user, "admin", {:system, "auto_admin"})
      end

    case result do
      {:ok, user} ->
        user

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp admin_email do
    Admins.bootstrap_email()
  end

  defp display_name_for(email) do
    email
    |> String.split("@")
    |> hd()
    |> String.replace(~r/[._-]+/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
    |> case do
      "" -> email
      name -> name
    end
  end

  # ---------------------------------------------------------------------------
  # Magic links
  # ---------------------------------------------------------------------------

  @doc """
  Sends a single-use sign-in link.

  Unknown addresses only receive a link when self sign-up is enabled; otherwise
  they get the same response, which avoids leaking which addresses exist.
  """
  def request_login(email) do
    email = User.normalise_email(email)

    with {:ok, user} <- login_user(email) do
      plain = random_token()

      {:ok, _token} =
        %LoginToken{}
        |> LoginToken.changeset(%{
          user_id: user.id,
          token_hash: hash(plain),
          expires_at: DateTime.add(now(), login_token_minutes(), :minute)
        })
        |> Repo.insert()

      Audit.log(Audit.system_actor(), User.audit_event_login_requested(user))

      user
      |> ConfluencePhxMirror.Accounts.Emails.login_link(magic_link_url(plain))
      |> Mailer.deliver()
      |> case do
        {:ok, _} -> {:ok, :sent}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp login_user(email) do
    case get_user_by_email(email) do
      nil ->
        # Seeded administrators (CM_ADMINS) can always sign in: otherwise a new
        # deployment would need self sign-up just to reach the admin screens.
        # Everybody else is the deployment's `UserPolicy` to admit.
        if Admins.seeded?(email) or
             UserPolicy.allows?(%{email: email}, :sign_in) do
          ensure_user(email)
        else
          {:error, :unknown_email}
        end

      user ->
        if User.disabled?(user), do: {:error, :disabled}, else: {:ok, user}
    end
  end

  @doc "Consumes a magic link. Tokens are single-use and expire after 15 minutes."
  def consume_login(plain) when is_binary(plain) do
    now = now()

    case Repo.one(
           from t in LoginToken,
             where: t.token_hash == ^hash(plain) and is_nil(t.used_at),
             preload: [:user]
         ) do
      nil ->
        {:error, :invalid}

      %LoginToken{} = token ->
        cond do
          DateTime.compare(token.expires_at, now) == :lt ->
            {:error, :expired}

          # The link may have been requested before the account was switched
          # off; consuming it must not undo that.
          User.disabled?(token.user) ->
            {:error, :disabled}

          true ->
            sign_in(token, now)
        end
    end
  end

  defp sign_in(token, now) do
    Repo.transaction(fn ->
      {:ok, _} = token |> Ecto.Changeset.change(used_at: now) |> Repo.update()
      {:ok, user} = record_sign_in(token.user)
      user
    end)
  end

  defp magic_link_url(token) do
    ConfluencePhxMirrorWeb.Endpoint.url() <> "/session/" <> token
  end

  # ---------------------------------------------------------------------------
  # API tokens
  # ---------------------------------------------------------------------------

  @doc """
  Creates an API token. The plaintext is returned once and never stored — what
  is kept is an Argon2id digest under the policy in `TokenHash`.
  """
  def create_api_token(%User{} = user, name, actor) do
    plain = random_token()

    with {:ok, token} <-
           %ApiToken{}
           |> ApiToken.changeset(%{
             user_id: user.id,
             name: name,
             token_hash: TokenHash.hash(plain),
             token_prefix: prefix_of(plain)
           })
           |> Repo.insert() do
      Audit.log(actor, ApiToken.audit_event_created(token, user))

      {:ok, plain, token}
    end
  end

  def list_api_tokens(%User{id: user_id}) do
    Repo.all(from t in ApiToken, where: t.user_id == ^user_id, order_by: [desc: t.inserted_at])
  end

  def revoke_api_token(%User{id: user_id}, token_id, actor) do
    case Repo.get_by(ApiToken, id: token_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      token ->
        {:ok, _} = Repo.delete(token)

        Audit.log(actor, ApiToken.audit_event_revoked(token))

        :ok
    end
  end

  @doc "Authenticates a bearer token."
  def authenticate_api_token(plain) when is_binary(plain) do
    now = now()
    query = from t in ApiToken, where: not is_nil(t.user_id), preload: [:user]

    with {:ok, token} <- find_token(plain, query) do
      cond do
        expired?(token, now) ->
          {:error, :expired_token}

        User.disabled?(token.user) ->
          {:error, :account_disabled}

        true ->
          touch(token, now)
          {:ok, token.user}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Service tokens (no user, one scope)
  # ---------------------------------------------------------------------------

  @doc "Tokens that belong to an integration rather than to a reader."
  def list_service_tokens do
    Repo.all(
      from t in ApiToken,
        where: is_nil(t.user_id),
        order_by: [asc: t.name]
    )
  end

  @doc """
  Creates a service token. The plaintext is returned once and never stored —
  what is kept is an Argon2id digest under the policy in `TokenHash`.
  """
  def create_service_token(name, scope, actor) do
    plain = random_token()

    with {:ok, token} <-
           %ApiToken{}
           |> ApiToken.changeset(%{
             name: name,
             scope: scope,
             token_hash: TokenHash.hash(plain),
             token_prefix: prefix_of(plain)
           })
           |> Repo.insert() do
      Audit.log(actor, ApiToken.audit_event_service_created(token))

      {:ok, plain, token}
    end
  end

  def revoke_service_token(id, actor) do
    case Repo.one(from t in ApiToken, where: is_nil(t.user_id) and t.id == ^id) do
      nil ->
        {:error, :not_found}

      token ->
        {:ok, _} = Repo.delete(token)
        Audit.log(actor, ApiToken.audit_event_revoked(token))
        :ok
    end
  end

  @doc "Authenticates a service token that was issued for `scope`."
  def authenticate_service_token(plain, scope) when is_binary(plain) do
    now = now()

    query =
      from t in ApiToken,
        where: is_nil(t.user_id) and t.scope == ^scope

    with {:ok, token} <- find_token(plain, query) do
      if expired?(token, now) do
        {:error, :expired_token}
      else
        touch(token, now)
        {:ok, token}
      end
    end
  end

  defp touch(%ApiToken{} = token, now) do
    {:ok, _} = token |> Ecto.Changeset.change(last_used_at: now) |> Repo.update()
    :ok
  end

  @doc "Authenticates `email:token` basic credentials, for Confluence-style clients."
  def authenticate_basic(email, plain) do
    with %User{} = user <- get_user_by_email(email),
         {:ok, %User{id: id}} <- authenticate_api_token(plain) do
      if id == user.id, do: {:ok, user}, else: {:error, :invalid_token}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp expired?(%ApiToken{expires_at: nil}, _now), do: false

  defp expired?(%ApiToken{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  # A digest is salted, so it cannot be looked up by equality: the prefix narrows
  # the table to the row that could match, and the token itself decides. A token
  # that verifies against a digest written under an older policy is re-written
  # here — that is what makes changing the algorithm a decision rather than a
  # migration of live credentials.
  defp find_token(plain, query) do
    query
    |> where([t], t.token_prefix == ^prefix_of(plain))
    |> Repo.all()
    |> Enum.find_value({:error, :invalid_token}, fn token ->
      case TokenHash.verify(plain, token.token_hash) do
        :error -> nil
        :current -> {:ok, token}
        :legacy -> {:ok, upgrade_digest(token, plain)}
      end
    end)
  end

  defp upgrade_digest(%ApiToken{} = token, plain) do
    {:ok, upgraded} =
      token
      |> Ecto.Changeset.change(token_hash: TokenHash.hash(plain))
      |> Repo.update()

    upgraded
  end

  defp prefix_of(plain), do: String.slice(plain, 0, @token_prefix_length)

  # A magic-link token lives for one sign-in and is looked up by digest, so it
  # keeps the fast hash: there is no stored digest to attack offline.
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp random_token,
    do: :crypto.strong_rand_bytes(@api_token_bytes) |> Base.url_encode64(padding: false)
end
