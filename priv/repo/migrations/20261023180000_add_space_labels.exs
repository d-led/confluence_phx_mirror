defmodule ConfluencePhxMirror.Repo.Migrations.AddSpaceLabels do
  use Ecto.Migration

  # The labels a space itself carries — Confluence calls the one with the `team`
  # prefix a *category* and shows it in the space directory. They are not page
  # labels: those stay in `page_labels`.
  def change do
    alter table(:spaces) do
      add :labels, {:array, :string}, null: false, default: []
    end
  end
end
