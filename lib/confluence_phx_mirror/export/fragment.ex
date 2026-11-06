defmodule ConfluencePhxMirror.Export.Fragment do
  @moduledoc """
  The place a link names inside a document.

  A fragment is neither a file nor an address: it is a heading, an anchor, a
  place. Both archives rewrite paths — one to a file beside the page, one to
  the site's address for something it does not carry — and both have to leave
  the fragment where the writer put it, or a reader who follows a table of
  contents lands at the top of the document instead of at the words they chose.

  One rule, written once, because an export that keeps it and an export that
  drops it look the same until somebody presses a link.
  """

  @doc """
  Puts the fragment of `original` on `rewritten`, unless it already carries one.

      iex> keep("../Macros/Macros.md", "/spaces/ENG/pages/1003/macros#Overview")
      "../Macros/Macros.md#Overview"

      iex> keep("../Macros/Macros.md#Kept", "/spaces/ENG/pages/1003/macros#Overview")
      "../Macros/Macros.md#Kept"
  """
  @spec keep(String.t(), String.t() | nil) :: String.t()
  def keep(rewritten, original) do
    case {of(original), String.contains?(rewritten, "#")} do
      {place, false} when is_binary(place) -> rewritten <> "#" <> place
      _nothing_to_keep -> rewritten
    end
  end

  @doc """
  The fragment of an address, or nil when it names no place.

      iex> of("/spaces/ENG/pages/1003/macros#Overview")
      "Overview"

      iex> of("/spaces/ENG/pages/1003/macros")
      nil
  """
  @spec of(String.t() | nil) :: String.t() | nil
  def of(href) do
    case String.split(href || "", "#", parts: 2) do
      [_path, place] when place != "" -> place
      _no_place -> nil
    end
  end
end
