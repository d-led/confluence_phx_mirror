defmodule ConfluencePhxMirror.Sync.Embeds.Frame do
  @moduledoc """
  The frame the mirror writes, wherever a third party's page is shown.

  Two paths reach a frame and they produce the same node: a widget connector
  whose macro the export left unexpanded (`Renderers.WidgetConnector`, which
  knows the address the vendor's player is served from) and the site's own
  `iframe`, which the export carries for a connector it rendered — kept by
  `Sync.Renderer` where an operator allowed the host. One node means one set of
  rules for the stylesheet and for the content security policy.

  Every frame gets: the address, a title naming the party, `sandbox` so a third
  party's scripts cannot reach this page's, the site's origin and nothing more as
  the referrer, and lazy loading — a page of embeds must not load ten players
  nobody scrolled to.

  The referrer is `origin` rather than `no-referrer` because a player may refuse
  to start without one: measured on the capture page, YouTube answers
  `no-referrer` with "Error 153, player configuration error"
  (`embedder.identity.missing.referrer`) and plays with `origin`. The origin is a
  host, not a page, so the third party learns where the mirror is and not what a
  reader is looking at.

  A declared `height` is the frame's, inside the band a player is built for,
  because a player comes in its vendor's sizes and a frame drawn at the mirror's
  own 16:9 is a different picture. The width never is: the frame fills the
  reading column, where a fixed 600px box is a narrow strip on a wide screen and
  a sideways scroll on a phone.
  """

  @sandbox "allow-scripts allow-same-origin allow-popups allow-presentation"

  # The page's address is not the third party's business, but a player may refuse
  # to start with no referrer at all, so the site's origin is sent and no more.
  @referrer "origin"

  # The bands a player is drawn at, and the ones a frame may be put in: a
  # declared height outside this is clamped rather than obeyed.
  @min_height 120
  @max_height 1200

  @doc """
  The `iframe` node for `src`, which the caller has already decided it may draw.

      iex> node("https://www.youtube.com/embed/abc", height: "300px")
      {"iframe",
       [{"class", "mirror-embed"}, {"src", "https://www.youtube.com/embed/abc"},
        {"title", "Embedded content from www.youtube.com"}, {"loading", "lazy"},
        {"referrerpolicy", "origin"},
        {"sandbox", "allow-scripts allow-same-origin allow-popups allow-presentation"},
        {"allowfullscreen", ""}, {"style", "height:300px"}], []}
  """
  @spec node(String.t(), keyword()) :: Floki.html_node()
  def node(src, opts \\ []) do
    href = to_string(src)

    {"iframe",
     [
       {"class", "mirror-embed"},
       {"src", href},
       {"title", "Embedded content from #{host(href)}"},
       {"loading", "lazy"},
       {"referrerpolicy", @referrer},
       {"sandbox", @sandbox},
       {"allowfullscreen", ""}
     ] ++ size(Keyword.get(opts, :height)), []}
  end

  # A declared height is the vendor's own band, so it is written on the frame and
  # the stylesheet's 16:9 stands aside; anything that is not a pixel count — the
  # macro's `width`, a percentage, an empty parameter — leaves the frame at the
  # shape the stylesheet gives it.
  defp size(height) do
    case pixels(height) do
      nil -> []
      pixels -> [{"style", "height:#{pixels}px"}]
    end
  end

  defp pixels(value) when is_binary(value) do
    case Regex.run(~r/\A\s*(\d{1,4})\s*(?:px)?\s*\z/i, value) do
      [_pixels, number] ->
        number |> String.to_integer() |> max(@min_height) |> min(@max_height)

      _not_a_pixel_count ->
        nil
    end
  end

  defp pixels(_value), do: nil

  defp host(href), do: href |> URI.parse() |> Map.get(:host) |> to_string()
end
