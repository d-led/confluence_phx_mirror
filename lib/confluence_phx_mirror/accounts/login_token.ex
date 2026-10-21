defmodule ConfluencePhxMirror.Accounts.LoginToken do
  @moduledoc """
  Single-use magic-link token. Magic links keep the mirror passwordless: an
  account is created on first sign-in when self sign-up is enabled.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "login_tokens" do
    field :token_hash, :string, redact: true
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, ConfluencePhxMirror.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :token_hash, :expires_at])
    |> validate_required([:user_id, :token_hash, :expires_at])
    |> unique_constraint(:token_hash)
  end
end
