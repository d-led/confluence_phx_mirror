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

  require Ecto.Query

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

  @doc """
  A window, on either engine.

  Postgres reads `LIMIT NULL` as "no limit" and allows `OFFSET` on its own;
  SQLite refuses the first as a datatype mismatch and the second as a syntax
  error. No limit is therefore no clause at all — offset included, because an
  offset with nothing to offset from is not a window either engine has a use for.
  """
  @spec paged(Ecto.Queryable.t(), pos_integer() | nil, non_neg_integer()) :: Ecto.Queryable.t()
  def paged(query, nil, _offset), do: query

  def paged(query, limit, offset) do
    query
    |> Ecto.Query.limit(^limit)
    |> Ecto.Query.offset(^offset)
  end
end
