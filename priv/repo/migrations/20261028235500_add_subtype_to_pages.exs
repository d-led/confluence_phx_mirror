defmodule ConfluencePhxMirror.Repo.Migrations.AddSubtypeToPages do
  use Ecto.Migration

  # Confluence calls a page several people edit at once a *live doc*, and says so
  # with `subtype: "live"` on content that is otherwise an ordinary page. A
  # mirror is always a snapshot, and a live doc is the one page whose age a
  # reader should be told about; without the column the mirror cannot tell it
  # from any other page.
  def change do
    alter table(:pages) do
      add :subtype, :string
    end
  end
end
