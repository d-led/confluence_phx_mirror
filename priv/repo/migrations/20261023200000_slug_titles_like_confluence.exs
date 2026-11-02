defmodule ConfluencePhxMirror.Repo.Migrations.SlugTitlesLikeConfluence do
  @moduledoc """
  Rewrites `pages.slug` to the rule Confluence itself uses, so a Confluence page
  URL works here with the host swapped and nothing else.

  Confluence keeps `[A-Za-z0-9_]` and turns every other run into a single `+`
  (`"API /v2: changelog? (draft) #2"` → `API+v2+changelog+draft+2`), and leaves
  the segment empty when nothing survives — a Cyrillic or CJK title is served by
  id alone. The old rule here lower-cased, hyphenated and always produced a
  segment, so every existing row needs the new form; the id is still what
  identifies the page, and any old URL redirects to the new canonical one.
  """
  use Ecto.Migration

  # Rewriting `slug` for the rows a deployment already has. SQLite is created
  # empty by this migration set and its ingest writes the new rule as it goes, so
  # there is nothing to rewrite — and `ALTER COLUMN`, which is how the column
  # stops being required, is Postgres-only.
  def up do
    if ConfluencePhxMirror.Migration.postgres?() do
      # A title with no ASCII words in it has no segment at all, so the column
      # stops being required: NULL is "serve this page by its id".
      execute("ALTER TABLE pages ALTER COLUMN slug DROP NOT NULL")

      execute("""
      UPDATE pages
      SET slug = nullif(
                   trim(both '+' from left(regexp_replace(title, '[^A-Za-z0-9_]+', '+', 'g'), 255)),
                   ''
                 )
      """)
    end
  end

  def down do
    if ConfluencePhxMirror.Migration.postgres?() do
      execute("""
      UPDATE pages
      SET slug = coalesce(
                   nullif(
                     trim(both '-' from left(lower(regexp_replace(title, '[^a-z0-9]+', '-', 'g')), 80)),
                     ''
                   ),
                   'page'
                 )
      """)

      execute("ALTER TABLE pages ALTER COLUMN slug SET NOT NULL")
    end
  end
end
