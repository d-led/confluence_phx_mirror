defmodule ConfluencePhxMirror.Query do
  @moduledoc """
  The one query construct whose spelling depends on the engine.

  `ilike/2` is Postgres. `ecto_sqlite3` refuses it at compile time, which is how
  every typed filter in the mirror became a 500 in the desktop build: the space
  directory, a space's page list, labels, people, attachments, the trash, the
  audit list. The question those filters ask is the same on either engine — "does
  this column contain this, ignoring case" — and `lower(?) LIKE lower(?)` is how
  both spell it.

  `ESCAPE '\\'` is not decoration. The patterns these filters build escape the
  reader's own `%`, `_` and `\\` with a backslash; Postgres makes backslash the
  default escape character and SQLite has no default, so without the clause a
  search for `50%` would be a wildcard here and a literal there.
  """

  @doc """
  Case-insensitive `LIKE`, on either engine.

  `pattern` is what the callers' `like_pattern/1`-style helpers build: the term
  surrounded by `%`, with its own `%`, `_` and `\\` escaped.
  """
  defmacro like_ci(field, pattern) do
    quote do
      fragment("lower(?) LIKE lower(?) ESCAPE '\\'", unquote(field), unquote(pattern))
    end
  end
end
