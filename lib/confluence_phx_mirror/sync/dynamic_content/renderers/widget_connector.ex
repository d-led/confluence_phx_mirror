defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.WidgetConnector do
  @moduledoc """
  *Widget Connector*: somebody else's page, shown inside this one.

      <ac:structured-macro ac:name="widget">
        <ac:parameter ac:name="url">https://www.youtube.com/watch?v=abc</ac:parameter>
      </ac:structured-macro>

  Confluence resolves this in the reader's browser, so `export_view` carries an
  unexpanded macro and a static mirror used to print "an external widget" and
  stop. What the macro holds is an address, and an address is enough to draw it:
  a frame, when this deployment allows the host, with the address printed under
  it in muted type and still a link.

  The address is always there, because the frame is the part that may be
  missing — a host nobody allowed (`Sync.Embeds`), a page in a space a stranger
  may read, which is stored without a frame because one copy of a body is served
  to every reader, an export opened offline, or a third party that is down. A
  reader who gets no frame gets the address rather than an empty box.

  The macro also records a `width` and a `height`, and only the height is
  obeyed. A player comes in its vendor's bands — 300px, 315px — and a frame
  drawn at the mirror's own 16:9 is a different picture, so a declared height is
  kept, within a readable range: below it the frame is a strip, and a page is not
  allowed to hand a reader a screenful it never drew. The width is the mirror's:
  the frame fills the reading column, where a fixed 600px frame is a narrow box
  on a wide screen and a sideways scroll on a phone.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Publishing
  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}
  alias ConfluencePhxMirror.Sync.Embeds

  @sandbox "allow-scripts allow-same-origin allow-popups allow-presentation"

  # The bands a player is drawn at, and the ones a frame may be put in: a
  # declared height outside this is clamped rather than obeyed.
  @min_height 120
  @max_height 1200

  @impl true
  def render(attrs, %Context{} = context) do
    case address(attrs) do
      nil -> [Nodes.notice("Widget connector: the macro names no address.")]
      address -> block(address, attrs, context)
    end
  end

  # A macro that names an address we will not follow says so; the words are
  # quoted, not linked, because a `javascript:` value is not a link.
  defp block(address, attrs, context) do
    case Embeds.linkable?(address) do
      :error ->
        [Nodes.notice("Widget connector: #{inspect(address)} is not a web address.")]

      {:ok, href} ->
        case frame(address, context) do
          nil -> [address_line(["Embedded content: ", link(href)])]
          src -> [iframe(src, href, attrs), address_line([link(href)])]
        end
    end
  end

  # The frame is for an address this deployment allows *and* a space no stranger
  # can reach: a public deployment serves one stored body to everybody, so the
  # body a stranger opens must not load a third party for anyone.
  defp frame(address, context) do
    with {:ok, src} <- Embeds.embeddable?(address),
         false <- stranger_reachable?(context) do
      src
    else
      _refused -> nil
    end
  end

  defp stranger_reachable?(%Context{space: space}), do: Publishing.stranger_reachable?(key(space))

  defp key(%{key: key}), do: key
  defp key(_space), do: nil

  defp iframe(src, href, attrs) do
    {"iframe",
     [
       {"class", "mirror-embed"},
       {"src", src},
       {"title", "Embedded content from #{host(href)}"},
       {"loading", "lazy"},
       {"referrerpolicy", "no-referrer"},
       {"sandbox", @sandbox},
       {"allowfullscreen", ""}
     ] ++ size(attrs), []}
  end

  # A declared height is the vendor's own band, so it is written on the frame and
  # the stylesheet's 16:9 stands aside; anything that is not a pixel count — the
  # macro's `width`, a percentage, an empty parameter — leaves the frame at the
  # shape the stylesheet gives it.
  defp size(attrs) do
    case declared_height(Map.get(attrs, "height")) do
      nil -> []
      pixels -> [{"style", "height:#{pixels}px"}]
    end
  end

  defp declared_height(value) when is_binary(value) do
    case Regex.run(~r/\A\s*(\d{1,4})\s*(?:px)?\s*\z/i, value) do
      [_pixels, number] ->
        number |> String.to_integer() |> max(@min_height) |> min(@max_height)

      _not_a_pixel_count ->
        nil
    end
  end

  defp declared_height(_value), do: nil

  defp address_line(children),
    do: {"p", [{"class", "mirror-embed-source mirror-embed-address"}], children}

  defp link(href) do
    {"a", [{"href", href}, {"rel", "noopener noreferrer nofollow"}], [href]}
  end

  defp host(href), do: href |> URI.parse() |> Map.get(:host) |> to_string()

  # The macro's address is the parameter Confluence calls `url`; a marker built
  # from storage reaches us with the same word, and `data-url` is how the
  # expander spells it.
  defp address(attrs), do: blank_to_nil(Map.get(attrs, "url"))

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
