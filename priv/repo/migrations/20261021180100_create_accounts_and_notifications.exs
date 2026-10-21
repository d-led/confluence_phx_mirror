defmodule ConfluencePhxMirror.Repo.Migrations.CreateAccountsAndNotifications do
  @moduledoc """
  Mirror-local accounts (never Confluence accounts), API tokens, magic-link
  login tokens, subscriptions and the notification outbox.
  """
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :display_name, :string
      add :role, :string, null: false, default: "member"
      add :last_sign_in_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, ["lower(email)"])

    create table(:api_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :token_prefix, :string, null: false
      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])

    create table(:login_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:login_tokens, [:token_hash])
    create index(:login_tokens, [:user_id])

    create table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :target_type, :string, null: false
      add :target_id, :bigint, null: false
      add :frequency, :string, null: false, default: "instant"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:subscriptions, [:user_id, :target_type, :target_id])
    create index(:subscriptions, [:target_type, :target_id])

    create table(:notifications) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :subject, :string, null: false
      add :body, :text, null: false
      add :page_id, references(:pages, on_delete: :nilify_all)
      add :delivered_at, :utc_datetime
      add :error, :text
      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:user_id, :inserted_at])
    create index(:notifications, [:delivered_at])
  end
end
