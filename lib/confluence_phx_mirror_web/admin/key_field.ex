defmodule ConfluencePhxMirrorWeb.Admin.KeyField do
  @moduledoc """
  A comma-separated list of space keys, as a text field holds it.

  The runtime whitelist is one field for a list, and an operator types into it
  one key at a time. Two questions follow from that, and both are about the text
  rather than about the whitelist itself: which segment is being typed right now
  (so the suggestion list can answer it), and where a picked key belongs (so
  completing `ENG, LO` with `LOAD01` does not leave `ENG, LO, LOAD01` behind).
  """

  @doc "The keys the field names, in the order it names them."
  @spec keys(String.t() | nil) :: [String.t()]
  def keys(text) do
    text |> segments() |> Enum.reject(&blank?/1)
  end

  @doc """
  The keys the field has already settled on — what a suggestion must not offer
  again.

  The segment being typed is *not* one of them: `eng` is a search, not a
  decision, and counting it would filter out the very space the operator is
  spelling.
  """
  @spec named(String.t() | nil) :: [String.t()]
  def named(text) do
    text |> segments() |> Enum.drop(-1) |> Enum.reject(&blank?/1)
  end

  @doc """
  The segment being typed: what a suggestion list should match on.

  Blank when the field is empty or when the operator has just typed a comma —
  the second case is a request for the whole list, not for nothing, so
  `open?/1` says whether a list belongs under the field at all.
  """
  @spec pending(String.t() | nil) :: String.t()
  def pending(nil), do: ""
  def pending(text), do: text |> segments() |> List.last() |> blank_to_empty()

  @doc """
  Whether a suggestion list belongs under the field right now.

  A field nobody has typed into offers nothing; a field that ends in a comma
  offers everything that is left, because a comma is the operator saying "another
  one".
  """
  @spec open?(String.t() | nil) :: boolean()
  def open?(nil), do: false

  def open?(text) do
    pending(text) != "" or String.ends_with?(String.trim(to_string(text)), ",")
  end

  @doc """
  Where a picked `key` goes in `text`.

  A key the field already names is spelled the way the site spells it and is not
  written twice; a segment the key extends, or the blank one after a comma, is
  where it belongs; anything else keeps what was typed and adds the key after it.
  """
  @spec complete(String.t() | nil, String.t()) :: String.t()
  def complete(text, key) do
    segments = segments(text)
    typed = List.last(segments) || ""
    named = Enum.reject(segments, &blank?/1)

    cond do
      already_named?(named, key) ->
        named |> canonical(key) |> Enum.join(", ")

      prefix?(typed, key) ->
        segments |> replace_last(key) |> Enum.reject(&blank?/1) |> Enum.join(", ")

      true ->
        Enum.join(named ++ [key], ", ")
    end
  end

  defp already_named?(named, key) do
    wanted = String.upcase(key)
    Enum.any?(named, &(String.upcase(&1) == wanted))
  end

  # A picked key is the site's spelling of itself, so the field adopts it.
  defp canonical(named, key) do
    wanted = String.upcase(key)
    Enum.map(named, fn segment -> if String.upcase(segment) == wanted, do: key, else: segment end)
  end

  defp prefix?(typed, key) do
    String.starts_with?(String.upcase(key), String.upcase(typed))
  end

  defp replace_last([], key), do: [key]
  defp replace_last(segments, key), do: List.replace_at(segments, -1, key)

  defp segments(nil), do: [""]
  defp segments(text), do: text |> to_string() |> String.split(",") |> Enum.map(&String.trim/1)

  defp blank?(segment), do: segment == ""

  defp blank_to_empty(nil), do: ""
  defp blank_to_empty(segment), do: segment
end
