defmodule ConfluencePhxMirror.Sync.Emoticons do
  @moduledoc """
  Confluence's emoticons as the characters they stand for.

  The editor stores an emoticon as markup, never as punctuation, and
  Confluence's own `export_view` renders that markup as an image:

      <img class="emoticon emoticon-tick" data-emoticon-name="tick"
           data-emoji-fallback=":check_mark:" alt="(tick)"
           src="…/images/icons/emoticons/check.png" />

  An anonymous reader of the mirror cannot load that image — it lives on the
  Confluence site and needs a session — so the mirror replaces it with the
  character. Typed `:)`, `(y)` and `:smile:` are not touched: Confluence leaves
  them as text in the export, and in prose the same characters can be a
  coordinate, a checklist or code.

  Resolution order follows what Confluence would have drawn:

    1. `data-emoji-fallback`, the literal character stored for every emoji
       whose short name is outside the classic set;
    2. `data-emoticon-name`, the classic name (`tick`, `thumbs-up`, …);
    3. `data-emoji-shortname` without its colons (`check_mark`, `info`, …);
    4. `alt`, which is the classic name in parentheses (`(tick)`);
    5. the file name, for exports that carry no data attributes.

  `html/1` applies the same rule to a body that was mirrored before this
  existed: it is the reason a mirror needs no resync for its emoticons to
  appear, and it changes nothing on a body the sync already converted.

  Confluence's own emoji set (`:big_grin:`, the blue-star family) has no
  Unicode character: `export_view` writes its shortcode as text, and the glyph
  lives only in `body.view` as a Confluence-hosted image. Nothing in the export
  distinguishes that text from prose, so it stays as it is.
  """

  # The classic emoticon set: what `<ac:name>` says before emoji short names
  # became the attribute. A name with a fallback never reaches this map.
  @legacy %{
    "tick" => "✅",
    "cross" => "❌",
    "warning" => "⚠️",
    "information" => "ℹ️",
    "plus" => "➕",
    "minus" => "➖",
    "question" => "❓",
    "light-on" => "💡",
    "light-off" => "💡",
    "yellow-star" => "⭐",
    "red-star" => "⭐",
    "green-star" => "⭐",
    "blue-star" => "⭐",
    "heart" => "❤️",
    "thumbs-up" => "👍",
    "thumbs-down" => "👎",
    "smile" => "🙂",
    "sad" => "🙁",
    "cheeky" => "😜",
    "laugh" => "😄",
    "wink" => "😉"
  }

  # Short names a few tools emit without a fallback. Everything else modern
  # carries `ac:emoji-fallback`, so this map stays small on purpose.
  @shortnames %{
    "check_mark" => "✅",
    "cross_mark" => "❌",
    "info" => "ℹ️",
    "thumbsup" => "👍",
    "thumbsdown" => "👎"
  }

  # Twemoji names a glyph by its code points: 1f44d, 1f1e9-1f1ea.
  @codepoints ~r/^[0-9a-f]{4,6}(?:-[0-9a-f]{4,6})*$/

  @image_name ~r/([^\/?#]+)\.(?:png|gif|svg|jpe?g)(?:[?#].*)?$/i

  @doc """
  The character an `<ac:emoticon>` element stands for, or `nil` when nothing in
  its attributes says what it is.
  """
  @spec from_attributes([{String.t(), String.t()}]) :: String.t() | nil
  def from_attributes(attrs) do
    character(attribute(attrs, "ac:emoji-fallback")) ||
      named(attribute(attrs, "ac:name")) ||
      named(attribute(attrs, "ac:emoji-shortname")) ||
      codepoints(attribute(attrs, "ac:emoji-id"))
  end

  @doc """
  The character an emoticon image stands for, or `nil` for every other image.

  An image counts as an emoticon when its class says so or when it comes from
  Confluence's emoticon icon path; a screenshot called `smile.png` is a
  screenshot and stays one.
  """
  @spec from_image([{String.t(), String.t()}]) :: String.t() | nil
  def from_image(attrs) do
    src = attribute(attrs, "src") || ""

    if emoticon_image?(attrs, src) do
      character(attribute(attrs, "data-emoji-fallback")) ||
        named(attribute(attrs, "data-emoticon-name")) ||
        named(attribute(attrs, "data-emoji-shortname")) ||
        named(attribute(attrs, "alt")) ||
        named(image_name(src)) ||
        codepoints(image_name(src))
    end
  end

  @doc """
  `html` with every emoticon it carries replaced by its character.

  A body mirrored before the renderer learned about emoticons still holds
  Confluence's emoticon images; running this on the way out gives the reader
  the character without a resync. On a body that already carries characters it
  returns the body unchanged.
  """
  @spec html(String.t() | nil) :: String.t() | nil
  def html(nil), do: nil

  def html(text) when is_binary(text) do
    text
    |> replace(~r{<ac:emoticon\b([^>]*)>(?:\s*</ac:emoticon>)?}i, &from_attributes/1, "")
    |> replace(~r{<img\b([^>]*?)>}i, &from_image/1, :keep)
  end

  defp replace(text, pattern, resolve, fallback) do
    Regex.replace(pattern, text, fn tag, source ->
      resolve.(attributes(source)) || if fallback == :keep, do: tag, else: fallback
    end)
  end

  # Confluence writes double-quoted attributes, and none of them contains `>`.
  defp attributes(source) do
    ~r/([\w:-]+)\s*=\s*"([^"]*)"/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [name, value] -> {name, value} end)
  end

  defp emoticon_image?(attrs, src) do
    class = attribute(attrs, "class") || ""
    "emoticon" in String.split(class) or String.contains?(src, "/emoticons/")
  end

  defp image_name(src) do
    case Regex.run(@image_name, src) do
      [_, name | _] -> name
      _ -> nil
    end
  end

  # `<ac:emoji-fallback=":smile:">` would be a name, not a character: only a
  # value that is not a shortcode counts as the literal emoji.
  defp character(value) when is_binary(value) do
    if String.starts_with?(value, ":") and String.ends_with?(value, ":"), do: nil, else: value
  end

  defp character(nil), do: nil

  defp attribute(attrs, key) do
    case List.keyfind(attrs, key, 0) do
      {_key, value} -> presence(value)
      nil -> nil
    end
  end

  defp presence(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp name(value) do
    value
    |> String.trim(":")
    |> String.trim("()")
    |> String.downcase()
  end

  defp named(nil), do: nil
  defp named(value), do: Map.get(@legacy, name(value)) || Map.get(@shortnames, name(value))

  defp codepoints(nil), do: nil

  defp codepoints(value) do
    value = String.downcase(String.trim(value))

    if Regex.match?(@codepoints, value) do
      value
      |> String.split("-")
      |> Enum.map_join(fn hex -> <<String.to_integer(hex, 16)::utf8>> end)
    end
  end
end
