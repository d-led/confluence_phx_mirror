defmodule ConfluencePhxMirror.Repo.Migrations.AddRenderRevisionToPages do
  @moduledoc """
  Which renderer drew a page's body.

  A page's version says when Confluence changed it, and a body is re-read when
  that moves. The renderer moves on its own schedule: a rule that decides how a
  body is drawn can change while the page it drew has not changed at all, and
  until now nothing recorded that — so a corrected renderer reached only the
  pages somebody happened to edit afterwards.

  `0` is "drawn before anybody counted", which is every page a mirror already
  holds. The next sync re-reads those, because `Sync.Renderer.revision/0` is
  higher than the number they carry.
  """
  use Ecto.Migration

  def change do
    alter table(:pages) do
      add :render_revision, :integer, null: false, default: 0
    end
  end
end
