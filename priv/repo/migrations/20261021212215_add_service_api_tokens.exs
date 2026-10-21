defmodule ConfluencePhxMirror.Repo.Migrations.AddServiceApiTokens do
  use Ecto.Migration

  def change do
    # A token without a user belongs to an integration, not a person: it can
    # call exactly the scope it was issued for (e.g. the webhook route).
    execute(
      "ALTER TABLE api_tokens ALTER COLUMN user_id DROP NOT NULL",
      "ALTER TABLE api_tokens ALTER COLUMN user_id SET NOT NULL"
    )

    alter table(:api_tokens) do
      add :scope, :string, null: false, default: "api"
    end

    create index(:api_tokens, [:scope])
  end
end
