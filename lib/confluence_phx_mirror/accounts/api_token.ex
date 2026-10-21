defmodule ConfluencePhxMirror.Accounts.ApiToken do
  @moduledoc """
  A bearer token for the read-only REST API.

  Only the SHA-256 hash of the token is stored; the plaintext is shown to the
  user once, when it is generated.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string, redact: true
    field :token_prefix, :string
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :user, ConfluencePhxMirror.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :name, :token_hash, :token_prefix, :expires_at])
    |> validate_required([:user_id, :name, :token_hash, :token_prefix])
    |> unique_constraint(:token_hash)
  end
end
