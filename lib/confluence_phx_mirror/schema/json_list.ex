defmodule ConfluencePhxMirror.Schema.JSONList do
  @moduledoc """
  A list, stored as JSON text.

  SQLite has no array type, and `ecto_sqlite3` raises on `{:array, _}`. The
  columns that need one — a page's labels and ancestors, a space's labels, an
  account's linked identities and groups — are read as lists and never filtered
  on, so JSON is a storage detail rather than a compromise: the alternative
  would be join tables answering questions nobody asks.

  Where the database has a real array type this module is not used at all; the
  schema field stays `{:array, _}` and this build never sees the column. Which
  one a build uses is chosen at compile time, like the adapter itself.

  Reading is forgiving on purpose. A row written by an older release, or edited
  by hand, should not stop an export; a value that is not a list becomes an
  empty one, which is also what "no labels" means.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(list) when is_list(list), do: {:ok, list}
  def cast(_other), do: :error

  @impl true
  def load(nil), do: {:ok, []}

  def load(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _not_a_list -> {:ok, []}
    end
  end

  @impl true
  def dump(nil), do: {:ok, "[]"}
  def dump(list) when is_list(list), do: {:ok, JSON.encode_to_iodata!(list)}
  def dump(_other), do: :error
end
