defmodule ConfluencePhxMirror.Desktop.Catalogue do
  @moduledoc """
  What the window reads from the catalogue.

  Only reads: copying a space is the server's `Sync`, reached through the `sync`
  queue (`ConfluencePhxMirror.Desktop.Jobs`), so nothing here writes a row. The
  tool had its own copy of the write loop once, and a copy is a second thing to
  keep right.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Repo

  @doc "How many pages the catalogue holds, per space key."
  @spec page_counts() :: %{String.t() => non_neg_integer()}
  def page_counts do
    from(p in Page,
      join: s in assoc(p, :space),
      group_by: s.key,
      select: {s.key, count(p.id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
