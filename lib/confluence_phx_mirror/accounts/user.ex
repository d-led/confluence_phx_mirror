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
    # Confluence identity used when evaluating mirrored permissions.
    field :confluence_account_id, :string
    field :groups, {:array, :string}, default: []

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
    cast(user, attrs, [:confluence_account_id, :groups])
  end

  def admin?(%__MODULE__{role: "admin"}), do: true
  def admin?(%__MODULE__{}), do: false

  @doc "Name to show in the UI."
  def display_name(%__MODULE__{display_name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{email: email}), do: email |> String.split("@") |> hd()

  @doc "Audit entry for a newly created reader account."
  def audit_event_created(%__MODULE__{} = user) do
    Entry.new("user.created", "user", user.id, %{email: user.email, role: user.role})
  end

  @doc "Audit entry for an account moving between admin and member."
  def audit_event_role_changed(%__MODULE__{} = user) do
    Entry.new("user.role_changed", "user", user.id, %{role: user.role})
  end

  @doc "Audit entry for the mirrored groups an account belongs to."
  def audit_event_groups_changed(%__MODULE__{} = user) do
    Entry.new("user.groups_changed", "user", user.id, %{groups: user.groups})
  end

  @doc "Audit entry for a magic link being sent."
  def audit_event_login_requested(%__MODULE__{} = user) do
    Entry.new("user.login_requested", "user", user.id, %{email: user.email})
  end

  @doc "Audit entry for a magic link being used."
  def audit_event_signed_in(%__MODULE__{} = user) do
    Entry.new("user.signed_in", "user", user.id, %{method: "magic_link"})
  end

  @doc "Audit entry for an account signing out."
  def audit_event_signed_out(%__MODULE__{} = user) do
    Entry.new("user.signed_out", "user", user.id)
  end
end
