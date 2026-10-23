defmodule ConfluencePhxMirror.Accounts.ApiToken do
  @moduledoc """
  A bearer token for the read-only REST API, or for one integration (a service
  token, with no user and one scope).

  Only a one-way digest of the token is stored — an Argon2id PHC string, see
  `ConfluencePhxMirror.Accounts.TokenHash` — and the plaintext is shown to the
  caller once, when it is generated. `token_prefix` is the indexed lookup key,
  because a salted digest cannot be searched by equality.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ConfluencePhxMirror.Audit.Entry

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string, redact: true
    field :token_prefix, :string
    field :scope, :string, default: "api"
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :user, ConfluencePhxMirror.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :name, :token_hash, :token_prefix, :expires_at, :scope])
    |> validate_required([:name, :token_hash, :token_prefix])
    |> validate_inclusion(:scope, ~w(api webhook))
    |> unique_constraint(:token_hash)
  end

  @doc "Audit entry for a token handed to a user (the plaintext is never stored)."
  def audit_event_created(%__MODULE__{} = token, user) do
    Entry.new("api_token.created", "api_token", token.id, %{
      user: user.email,
      name: token.name,
      prefix: token.token_prefix
    })
  end

  @doc "Audit entry for a revoked token."
  def audit_event_revoked(%__MODULE__{} = token) do
    Entry.new("api_token.revoked", "api_token", token.id, %{prefix: token.token_prefix})
  end

  @doc "Audit entry for a token issued to an integration rather than a person."
  def audit_event_service_created(%__MODULE__{} = token) do
    Entry.new("api_token.created", "api_token", token.id, %{
      kind: "service",
      name: token.name,
      prefix: token.token_prefix,
      scope: token.scope
    })
  end
end
