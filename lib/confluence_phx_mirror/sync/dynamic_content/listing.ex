defmodule ConfluencePhxMirror.Sync.DynamicContent.Listing do
  @moduledoc """
  The CQL a listing macro writes from its own parameters.

  Several macros ask the port the same question with one word changed — *Recently
  Updated* (pages and posts, newest change first) and *Blog Posts* (posts only,
  newest created first) — so the filters they share live here rather than twice,
  and a third macro inherits them by calling one function.

  Confluence writes a space and a label as comma-separated parameters, and CQL
  writes them as `space in (ENG, OPS)` / `label in (runbook)`. A plain word goes
  in bare; anything else is quoted, so a label with a space in it reads the same
  to the parser. What neither form can say — a value with a quote in it — is the
  parser's error to report, and the macro shows it rather than guessing.
  """

  alias ConfluencePhxMirror.Sync.DynamicContent.Attributes

  @named ~r/^[A-Za-z0-9_.-]+$/u

  @doc """
  The `space` and `label` filters the marker asked for, as one `and` clause.

      iex> filters(%{"spaces" => "ENG", "labels" => "needs review"})
      ~s(space in (ENG) and label in ("needs review"))

  A marker that names neither answers `""`.
  """
  @spec filters(map()) :: String.t()
  def filters(attrs) do
    [
      membership("space", Attributes.list(attrs, "spaces")),
      membership("label", Attributes.list(attrs, "labels"))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  defp membership(_field, []), do: nil

  defp membership(field, values), do: "#{field} in (#{Enum.map_join(values, ", ", &value/1)})"

  defp value(word) do
    if String.match?(word, @named), do: word, else: ~s("#{word}")
  end
end
