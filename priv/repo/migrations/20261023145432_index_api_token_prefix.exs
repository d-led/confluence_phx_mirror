defmodule ConfluencePhxMirror.Repo.Migrations.IndexApiTokenPrefix do
  use Ecto.Migration

  # Argon2 is salted, so a token can no longer be looked up by its digest: the
  # prefix is the lookup key, and the presented token is verified against the
  # digest of the row that prefix narrows down to.
  def change do
    create index(:api_tokens, [:token_prefix])
  end
end
