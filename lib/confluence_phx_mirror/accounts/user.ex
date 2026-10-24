defmodule ConfluencePhxMirror.Accounts.User do
  @moduledoc """
  A reader account of the mirror. Confluence accounts are never mirrored;
  these users only sign in to the read-only mirror to subscribe to updates and
  to use the API.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Audit.Entry

  @roles ~w(admin member)

  schema "users" do
    field :email, :string
    field :display_name, :string
    field :role, :string, default: "member"
    field :last_sign_in_at, :utc_datetime
    # When the sync made this account because the site named the person. Null
    # for an account someone claimed here (magic link, proxy, bootstrap): that
    # row is the mirror's own, and no sync may take it away.
    field :provisioned_at, :utc_datetime
    # Confluence identity used when evaluating mirrored permissions.
    field :confluence_account_id, :string
    # Further Confluence identities an administrator linked to this account:
    # one person, several Atlassian accounts. What may be read is the union, so
    # every permission rule asks `identity_keys/1` rather than this field.
    field :identity_account_ids, {:array, :string}, default: []
    # Groups an administrator granted here, kept across syncs. Confluence group
    # memberships come from the mirror itself (`Mirror.GroupMember`).
    field :groups, {:array, :string}, default: []
    # Switched off here by an administrator.
    field :disabled_at, :utc_datetime
    # Switched off on the mirrored site, as the sync last saw it.
    field :site_disabled_at, :utc_datetime
    # Gone from the site entirely — deleted or closed there, not merely off.
    field :site_deleted_at, :utc_datetime
    # Banned here by an administrator. A ban outranks every other flag and
    # blocks deletion, so it cannot be undone by signing in again.
    field :banned_at, :utc_datetime

    has_many :api_tokens, ConfluencePhxMirror.Accounts.ApiToken
    has_many :subscriptions, ConfluencePhxMirror.Notifications.Subscription

    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :display_name, :role, :last_sign_in_at])
    |> validate_required([:email])
    |> update_change(:email, &normalise_email/1)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/, message: "is not a valid e-mail address")
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:email, name: :users_lower_email_index)
  end

  def normalise_email(email) do
    email |> to_string() |> String.trim() |> String.downcase()
  end

  @doc """
  Sets the Confluence identity used for permission checks.

  Kept out of `changeset/2` so a reader can never grant themselves a group.
  """
  def identity_changeset(user, attrs) do
    cast(user, attrs, [:confluence_account_id, :identity_account_ids, :groups])
  end

  @doc "Whether the sync made this account, rather than somebody claiming it here."
  def provisioned?(%__MODULE__{provisioned_at: at}), do: not is_nil(at)

  @doc """
  The identifiers Confluence can name this account by: its e-mail address, the
  identity it signed in with, and every identity an administrator linked.

  The union is deliberate. A person with a personal account and a guest account
  is one person here; a group membership or a page restriction naming either of
  them is a permission for that person, and asking only one of them would hide
  the other half of their own space.
  """
  def identity_keys(%__MODULE__{} = user) do
    [normalise_email(user.email), user.confluence_account_id | user.identity_account_ids || []]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  def admin?(%__MODULE__{role: "admin"}), do: true
  def admin?(%__MODULE__{}), do: false

  @doc "Whether an administrator switched this account off here."
  def disabled_here?(%__MODULE__{disabled_at: at}), do: not is_nil(at)

  @doc "Whether the site says this account is no longer active."
  def disabled_on_site?(%__MODULE__{site_disabled_at: at}), do: not is_nil(at)

  @doc "Whether the site no longer has this account at all."
  def deleted_on_site?(%__MODULE__{site_deleted_at: at}), do: not is_nil(at)

  @doc "Whether an administrator banned this account here."
  def banned?(%__MODULE__{banned_at: at}), do: not is_nil(at)

  @doc """
  Whether the account may not be used. This is the access rule every door asks.

  A ban, a switch-off here, or an account Confluence no longer has are all
  final. An account Confluence merely switched off is refused too — the site
  decides who may read it — unless the deployment set
  `MIRROR_ALLOW_SITE_DISABLED_READERS`, which keeps the mirror readable for
  somebody the site has stood down but still lists.

  The flags stay independent so the screens can tell "we did this" from "the
  site did this"; what a reader may do is the answer below.
  """
  def disabled?(%__MODULE__{} = user) do
    banned?(user) or disabled_here?(user) or site_blocks_use?(user)
  end

  defp site_blocks_use?(user) do
    deleted_on_site?(user) or (disabled_on_site?(user) and not allow_site_disabled?())
  end

  defp allow_site_disabled? do
    Application.get_env(:confluence_phx_mirror, :allow_site_disabled_readers, false) == true
  end

  @doc "Name to show in the UI."
  def display_name(%__MODULE__{display_name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{email: email}), do: email |> String.split("@") |> hd()

  @doc "Audit entry for a newly created reader account."
  def audit_event_created(%__MODULE__{} = user) do
    Entry.new("user.created", "user", user.id, %{
      email: user.email,
      role: user.role,
      display_name: user.display_name,
      groups: Enum.join(user.groups || [], ", ")
    })
  end

  @doc "Audit entry for an account moving between admin and member."
  def audit_event_role_changed(%__MODULE__{} = user, previous_role) do
    Entry.new("user.role_changed", "user", user.id, %{
      email: user.email,
      from: previous_role,
      to: user.role
    })
  end

  @doc "Audit entry for the groups an account belongs to."
  def audit_event_groups_changed(%__MODULE__{} = user, previous_groups) do
    Entry.new("user.groups_changed", "user", user.id, %{
      email: user.email,
      from: Enum.join(previous_groups || [], ", "),
      to: Enum.join(user.groups || [], ", ")
    })
  end

  @doc """
  Audit entry for a Confluence identity linked to this account.

  Linking is an access decision — the identity brings its group memberships and
  its page restrictions — so it is recorded with the identity named, not only
  with the count.
  """
  def audit_event_identity_linked(%__MODULE__{} = user, account_id) do
    Entry.new("user.identity_linked", "user", user.id, %{
      email: user.email,
      identity: account_id,
      identities: Enum.join(user.identity_account_ids || [], ", ")
    })
  end

  @doc "Audit entry for a Confluence identity unlinked from this account."
  def audit_event_identity_unlinked(%__MODULE__{} = user, account_id) do
    Entry.new("user.identity_unlinked", "user", user.id, %{
      email: user.email,
      identity: account_id,
      identities: Enum.join(user.identity_account_ids || [], ", ")
    })
  end

  @doc "Audit entry for an administrator switching this account off here."
  def audit_event_disabled(%__MODULE__{} = user) do
    Entry.new("user.disabled", "user", user.id, %{
      email: user.email,
      at: timestamp(user.disabled_at)
    })
  end

  @doc "Audit entry for an administrator switching this account back on here."
  def audit_event_enabled(%__MODULE__{} = user) do
    Entry.new("user.enabled", "user", user.id, %{email: user.email})
  end

  @doc "Audit entry for the site reporting the account as not active."
  def audit_event_site_disabled(%__MODULE__{} = user) do
    Entry.new("user.site_disabled", "user", user.id, %{
      email: user.email,
      at: timestamp(user.site_disabled_at)
    })
  end

  @doc "Audit entry for the site reporting the account as active again."
  def audit_event_site_enabled(%__MODULE__{} = user) do
    Entry.new("user.site_enabled", "user", user.id, %{email: user.email})
  end

  @doc "Audit entry for the site no longer having this account at all."
  def audit_event_site_deleted(%__MODULE__{} = user) do
    Entry.new("user.site_deleted", "user", user.id, %{
      email: user.email,
      at: timestamp(user.site_deleted_at)
    })
  end

  @doc "Audit entry for a state the site reported, whichever one it was."
  def audit_event_for_site_state(%__MODULE__{} = user, :active),
    do: audit_event_site_enabled(user)

  def audit_event_for_site_state(%__MODULE__{} = user, :disabled),
    do: audit_event_site_disabled(user)

  def audit_event_for_site_state(%__MODULE__{} = user, :deleted),
    do: audit_event_site_deleted(user)

  @doc "Audit entry for an administrator banning this account here."
  def audit_event_banned(%__MODULE__{} = user) do
    Entry.new("user.banned", "user", user.id, %{
      email: user.email,
      at: timestamp(user.banned_at)
    })
  end

  @doc "Audit entry for an administrator lifting a ban."
  def audit_event_unbanned(%__MODULE__{} = user) do
    Entry.new("user.unbanned", "user", user.id, %{email: user.email})
  end

  @doc "Audit entry for an account being deleted, with what it was known by."
  def audit_event_deleted(%__MODULE__{} = user) do
    Entry.new("user.deleted", "user", user.id, %{
      email: user.email,
      role: user.role,
      disabled_here: disabled_here?(user),
      disabled_on_site: disabled_on_site?(user),
      deleted_on_site: deleted_on_site?(user)
    })
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  @doc "Audit entry for a magic link being sent."
  def audit_event_login_requested(%__MODULE__{} = user) do
    Entry.new("user.login_requested", "user", user.id, %{email: user.email})
  end

  @doc "Audit entry for a sign-in, and how the person proved who they are."
  def audit_event_signed_in(%__MODULE__{} = user, method \\ "magic_link") do
    Entry.new("user.signed_in", "user", user.id, %{email: user.email, method: method})
  end

  @doc "Audit entry for an account signing out."
  def audit_event_signed_out(%__MODULE__{} = user) do
    Entry.new("user.signed_out", "user", user.id, %{email: user.email})
  end
end
