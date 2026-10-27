defmodule ConfluencePhxMirrorWeb.Admin.Paging do
  @moduledoc """
  Reading a page number off the query string.

  A page is a URL, so it can hold anything a reader types or a link mangles:
  absent, empty, `0`, `-2`, `lots`, or a repeated `?page[]=1` that Phoenix hands
  over as a list. Only a positive whole number counts; everything else is the
  first page, because a pager that raises or renders an empty table on a bad
  link is worse than one that shows page one.

  The same goes for the filter: anything that is not text is no filter, and a
  filter that is only spaces is no filter either.
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

  @doc "How many rows `page` skips before the ones it shows."
  @spec offset(pos_integer(), pos_integer()) :: non_neg_integer()
  def offset(page, per_page), do: (page - 1) * per_page

  @doc "How many pages `total` rows make, never fewer than one."
  @spec page_count(non_neg_integer(), pos_integer()) :: pos_integer()
  def page_count(total, per_page), do: max(ceil(total / per_page), 1)

  @doc """
  The filter a screen should run: the text of `params[key]`, trimmed.

  A `nil`, a list or a number are all "no filter": a URL is typed by people and
  rewritten by tools, and neither is an error a list should show.
  """
  @spec query(map(), String.t()) :: String.t()
  def query(params, key \\ "q") do
    case Map.get(params, key) do
      text when is_binary(text) -> String.trim(text)
      _absent -> ""
    end
  end

  @doc """
  A list's address with the parameters that make it this list, for a link a
  reader can share.

  Parameters that name nothing — an empty filter, a nil — are left out, so the
  plain address stays the address of "everything".
  """
  @spec href(String.t(), map()) :: String.t()
  def href(path, params) do
    pairs =
      params
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)

    case pairs do
      [] -> path
      pairs -> path <> "?" <> URI.encode_query(pairs)
    end
  end
end
