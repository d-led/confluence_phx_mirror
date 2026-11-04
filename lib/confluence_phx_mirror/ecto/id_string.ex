defmodule ConfluencePhxMirror.Ecto.IdString do
  @moduledoc """
  An id the site gives as text, from a store that may hold it as a number.

  Confluence Cloud hands out attachment ids such as `"att164058"` beside the
  numeric ones, so the column is text — `AttachmentsConfluenceIdAsText` retypes
  it, and only Postgres can, because SQLite has no `ALTER COLUMN`. SQLite also
  gives a column declared `bigint` *integer affinity*: the string `"9003"` is
  stored as the number 9003 and reads back as one, which a `:string` field then
  refuses to load ("cannot load `9003` as type :string") and the mirror stops at
  the first attachment with a numeric id — on the tool, never on the deployment.

  Text is the domain's answer either way: the id is an identifier, not a number
  anything computes with. So this type says so, and accepts both spellings going
  in and coming out.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  def cast(_something_else), do: :error

  @impl true
  def load(value), do: cast(value)

  @impl true
  def dump(value), do: cast(value)
end
