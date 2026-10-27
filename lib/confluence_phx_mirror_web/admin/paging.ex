defmodule ConfluencePhxMirrorWeb.Admin.Paging do
  @moduledoc """
  Reading a page number off the query string.

  A page is a URL, so it can hold anything a reader types or a link mangles:
  absent, empty, `0`, `-2`, `lots`, or a repeated `?page[]=1` that Phoenix hands
  over as a list. Only a positive whole number counts; everything else is the
  first page, because a pager that raises or renders an empty table on a bad
  link is worse than one that shows page one.
  """

  @doc "The page a `?page=` value names, or 1 when it names none."
  @spec page_number(term()) :: pos_integer()
  def page_number(nil), do: 1

  def page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _not_a_page -> 1
    end
  end

  def page_number(value) when is_integer(value) and value > 0, do: value

  def page_number(_other), do: 1

  @doc "How many pages `total` rows make, never fewer than one."
  @spec page_count(non_neg_integer(), pos_integer()) :: pos_integer()
  def page_count(total, per_page), do: max(ceil(total / per_page), 1)
end
