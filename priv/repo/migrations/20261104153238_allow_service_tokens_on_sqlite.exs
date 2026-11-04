defmodule ConfluencePhxMirror.Repo.Migrations.AllowServiceTokensOnSqlite do
  @moduledoc """
  A token that belongs to an integration rather than a person, on the tool's
  SQLite too.

  `AddServiceApiTokens` dropped `api_tokens.user_id`'s NOT NULL with
  `ALTER COLUMN`, which is Postgres's spelling. The tool's catalogue kept the
  constraint, so issuing a webhook token there failed with "NOT NULL constraint
  failed: api_tokens.user_id" — the same code, the same intent, and a schema
  that disagreed. SQLite cannot alter a column in place, so the table is
  rebuilt: rename it aside, create it again without the constraint, copy the
  rows, drop the old one, put the four indexes back.

  A migration of its own rather than an edit to the one above, because the
  tool's catalogue has already recorded that one as applied and would never run
  it again.
  """
  use Ecto.Migration

  @table :api_tokens

  @columns ~s("id", "user_id", "name", "token_hash", "token_prefix", "last_used_at", "expires_at", "inserted_at", "updated_at", "scope")

  def up do
    unless ConfluencePhxMirror.Migration.postgres?(), do: rebuild(required: false)
  end

  def down do
    unless ConfluencePhxMirror.Migration.postgres?(), do: rebuild(required: true)
  end

  defp rebuild(required: required?) do
    constraint = if required?, do: " NOT NULL", else: ""

    execute(~s|ALTER TABLE "#{@table}" RENAME TO "#{@table}_old"|)

    execute("""
    CREATE TABLE "#{@table}" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "user_id" INTEGER#{constraint} CONSTRAINT "#{@table}_user_id_fkey"
        REFERENCES "users"("id") ON DELETE CASCADE,
      "name" TEXT NOT NULL,
      "token_hash" TEXT NOT NULL,
      "token_prefix" TEXT NOT NULL,
      "last_used_at" TEXT,
      "expires_at" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "scope" TEXT DEFAULT 'api' NOT NULL
    )
    """)

    execute("""
    INSERT INTO "#{@table}" (#{@columns}) SELECT #{@columns} FROM "#{@table}_old"
    """)

    # The indexes went with the renamed table, so they come back once it is gone.
    execute(~s(DROP TABLE "#{@table}_old"))

    execute(~s|CREATE UNIQUE INDEX "api_tokens_token_hash_index" ON "api_tokens" ("token_hash")|)
    execute(~s|CREATE INDEX "api_tokens_user_id_index" ON "api_tokens" ("user_id")|)
    execute(~s|CREATE INDEX "api_tokens_scope_index" ON "api_tokens" ("scope")|)
    execute(~s|CREATE INDEX "api_tokens_token_prefix_index" ON "api_tokens" ("token_prefix")|)
  end
end
