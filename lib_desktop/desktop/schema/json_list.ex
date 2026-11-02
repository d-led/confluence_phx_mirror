defmodule ConfluencePhxMirror.Desktop.Schema.JSONList do
  @moduledoc """
  A list, stored as JSON text.

  SQLite has no array type, and `ecto_sqlite3` raises on `{:array, _}`. Two
  columns need one: a page's labels and its ancestors. Neither is filtered on —
  the archive reads both as lists and walks pages rather than querying labels —
  so JSON is a storage detail, not a compromise: the alternative would be two
  join tables to answer questions nobody asks.

  Reading is forgiving on purpose. A row written by an older version, or one
  edited by hand, should not stop an export; a value that is not a list becomes
  an empty one, which is also what "no labels" means.
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
