defmodule ConfluencePhxMirror.Accounts.User do
  @moduledoc """
  A reader account of the mirror. Confluence accounts are never mirrored;
  these users only sign in to the read-only mirror to subscribe to updates and
  to use the API.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(admin member)

  schema "users" do
    field :email, :string
    field :display_name, :string
    field :role, :string, default: "member"
    field :last_sign_in_at, :utc_datetime

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

  def admin?(%__MODULE__{role: "admin"}), do: true
  def admin?(%__MODULE__{}), do: false

  @doc "Name to show in the UI."
  def display_name(%__MODULE__{display_name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{email: email}), do: email |> String.split("@") |> hd()
end
