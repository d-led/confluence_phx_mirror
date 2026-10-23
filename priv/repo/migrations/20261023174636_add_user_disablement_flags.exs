defmodule ConfluencePhxMirror.Repo.Migrations.AddUserDisablementFlags do
  use Ecto.Migration

  # Two independent facts, because different people decide them: `disabled_at`
  # is an administrator switching an account off on this mirror,
  # `site_disabled_at` is Confluence saying the account is no longer active.
  # Access is refused when either is set.
  def change do
    alter table(:users) do
      add :disabled_at, :utc_datetime
      add :site_disabled_at, :utc_datetime
    end
  end
end
