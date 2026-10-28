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

  Confluence's own emoji set has no Unicode character. The editor stores a
  picker's choice as markup that names it three ways and gives no fallback
  character:

      <ac:emoticon ac:name="blue-star" ac:emoji-shortname=":big_grin:"
                   ac:emoji-id="atlassian-big_grin" ac:emoji-fallback=":big_grin:" />

  and `export_view` writes it as the literal text `:big_grin:`, where nothing
  distinguishes it from prose. The **storage** is what tells the two apart, so
  `from_storage/2` replaces the shortcodes the storage names — and only those —
  with the nearest character Atlassian's sprite would have drawn. The rest of
  the body, including anything inside `<pre>` and `<code>`, is left as it is.
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

  # Atlassian's own emoji set: a sprite image on their side, no character, and
  # a shortname in storage (`atlassian-big_grin`). These are what this mirror
  # draws instead — the same names as the classic set where the two overlap.
  @emoji %{
    "big-grin" => "😁",
    "smile" => "🙂",
    "laugh" => "😆",
    "wink" => "😉",
    "cheeky" => "😜",
    "sad" => "🙁",
    "cry" => "😢",
    "angry" => "😠",
    "thumbs-up" => "👍",
    "thumbs-down" => "👎",
    "tick" => "✅",
    "cross" => "❌",
    "warning" => "⚠️",
    "information" => "ℹ️",
    "question" => "❓",
    "light-on" => "💡",
    "light-off" => "💡",
    "plus" => "➕",
    "minus" => "➖",
    "heart" => "❤️",
    "yellow-star" => "⭐",
    "red-star" => "⭐",
    "green-star" => "⭐",
    "blue-star" => "⭐"
  }

  # A run of markup the shortcodes inside must not touch: a code block, or any
  # tag, so an attribute is never rewritten.
  @verbatim ~r{(<pre\b[^>]*>.*?</pre>|<code\b[^>]*>.*?</code>|<[^>]*>)}is

  @image_name ~r/([^\/?#]+)\.(?:png|gif|svg|jpe?g)(?:[?#].*)?$/i

  @doc """
  The character an `<ac:emoticon>` element stands for, or `nil` when nothing in
  its attributes says what it is.
  """
  @spec from_attributes([{String.t(), String.t()}]) :: String.t() | nil
  def from_attributes(attrs) do
    character(attribute(attrs, "ac:emoji-fallback")) ||
      emoji(attribute(attrs, "ac:emoji-shortname")) ||
      emoji(attribute(attrs, "ac:emoji-id")) ||
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
        emoji(attribute(attrs, "data-emoji-shortname")) ||
        emoji(attribute(attrs, "data-emoji-id")) ||
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

  @doc """
  `html` with the shortcodes its `storage` says are emoticons replaced.

  An emoji from Confluence's own set has no fallback character, so the export
  view writes its shortcode as plain text — indistinguishable from prose. The
  storage markup is the only thing that says which of those words is an
  emoticon, so it decides what is replaced; a body whose storage names no
  emoticon comes back unchanged, and so does text inside `<pre>`/`<code>`.
  """
  @spec from_storage(String.t() | nil, String.t() | nil) :: String.t() | nil
  def from_storage(nil, _storage), do: nil

  def from_storage(html, storage) when is_binary(html) and is_binary(storage) do
    storage
    |> replaced_shortcodes()
    |> Enum.reduce(html, fn {shortcode, glyph}, text -> swap(text, shortcode, glyph) end)
  end

  def from_storage(html, _storage), do: html

  # `[{shortcode, glyph}]`: what the export writes in place of each emoticon the
  # storage marks up, and the character the mirror draws for it.
  defp replaced_shortcodes(storage) do
    ~r{<ac:emoticon\b([^>]*)>}i
    |> Regex.scan(storage, capture: :all_but_first)
    |> Enum.map(fn [source] -> source |> attributes() |> shortcode() end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp shortcode(attrs) do
    with glyph when is_binary(glyph) <- from_attributes(attrs),
         text when is_binary(text) <- exported_text(attrs) do
      {text, glyph}
    else
      _ -> nil
    end
  end

  # The fallback when it is a shortcode, else the shortname: both are what
  # `export_view` writes where it cannot draw the image.
  defp exported_text(attrs) do
    [attribute(attrs, "ac:emoji-fallback"), attribute(attrs, "ac:emoji-shortname")]
    |> Enum.find(&shortcode?/1)
  end

  defp shortcode?(value) when is_binary(value),
    do: String.starts_with?(value, ":") and String.ends_with?(value, ":")

  defp shortcode?(_value), do: false

  # Only the text between tags is rewritten: a run of markup comes back as it
  # went in, so `alt=":big_grin:"` and a code block keep their text.
  defp swap(text, shortcode, glyph) do
    @verbatim
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.map(fn part ->
      if String.starts_with?(part, "<"), do: part, else: String.replace(part, shortcode, glyph)
    end)
    |> IO.iodata_to_binary()
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
    if String.starts_with?(value, ":") and String.ends_with?(value, ":"),
      do: nil,
      else: unescape(value)
  end

  defp character(nil), do: nil

  # Confluence writes a few emoji into storage as escapes instead of a character
  # — `ac:emoji-fallback="\uD83D\uDDD3"` is a calendar, not twelve letters — and
  # an export view copies that text into the body, where a reader sees the
  # escape. A fallback that is nothing but escapes is decoded; a run that names
  # no character is no fallback at all, and the caller's next rule decides.
  @escapes ~r/^(?:\\u[0-9a-fA-F]{4})+$/
  @escaped_codepoint ~r/\\u([0-9a-fA-F]{4})/

  defp unescape(value) do
    if Regex.match?(@escapes, value), do: decode(value), else: value
  end

  defp decode(value) do
    codepoints =
      @escaped_codepoint
      |> Regex.scan(value, capture: :all_but_first)
      |> Enum.map(fn [hex] -> String.to_integer(hex, 16) end)

    case scalars(codepoints, []) do
      {:ok, characters} -> Enum.map_join(characters, &<<&1::utf8>>)
      :error -> nil
    end
  end

  # A surrogate half names nothing on its own; a high half followed by a low one
  # is the character between them.
  defp scalars([high, low | rest], characters)
       when high in 0xD800..0xDBFF and low in 0xDC00..0xDFFF,
       do: scalars(rest, [0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00) | characters])

  defp scalars([half | _rest], _characters) when half in 0xD800..0xDFFF, do: :error

  defp scalars([character | rest], characters),
    do: scalars(rest, [character | characters])

  defp scalars([], characters), do: {:ok, Enum.reverse(characters)}

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

  # `atlassian-big_grin` and `:big_grin:` name the same emoji: the prefix says
  # whose set it is, and the shortname spells it with underscores.
  defp emoji(nil), do: nil

  defp emoji(value) do
    value
    |> name()
    |> String.replace_prefix("atlassian-", "")
    |> String.replace("_", "-")
    |> then(&Map.get(@emoji, &1))
  end

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
