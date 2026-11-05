defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.NativeEmbed do
  @moduledoc """
  *Whiteboards and Databases*: drawn when the mirror can, linked when it cannot.

      <div class="mirror-macro" data-macro="native-embed:whiteboard"
           data-url="https://site/wiki/spaces/MFS/whiteboard/28344336"></div>

  A whiteboard's export view carries only an unknown-macro placeholder, but the
  board's document is readable over GraphQL and holds the nodes, their geometry
  and their words — so a whiteboard is drawn as a still picture of itself
  (`Sync.Whiteboard`). A database is a live view and is only named and linked.

  Anything that stops the drawing — no address, a fetch that fails, a document
  version this mirror does not know, a board with nothing in it — is answered
  with an apology and a link to the real thing, never with a silently empty box.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}
  alias ConfluencePhxMirror.Sync.Whiteboard

  @kinds %{
    "native-embed:database" => "Database",
    "native-embed:whiteboard" => "Whiteboard"
  }

  @impl true
  def render(attrs, %Context{} = context) do
    case url(attrs) do
      nil ->
        [
          Nodes.notice(
            "#{kind(attrs)}: the embed names no address, so the mirror cannot link to it."
          )
        ]

      url ->
        contents(attrs, url, context)
    end
  end

  # A whiteboard is drawn; anything else is named and linked.
  defp contents(%{"macro" => "native-embed:whiteboard"} = attrs, url, context) do
    case board(context, url) do
      {:ok, document} -> drawn(document, attrs, url)
      :error -> sorry(attrs, url)
    end
  end

  defp contents(attrs, url, _context) do
    [Nodes.notice("#{kind(attrs)} — drawn in Confluence; open it there."), address(url)]
  end

  defp board(context, url) do
    case context.source.whiteboard(context.page, url) do
      {:ok, document} -> {:ok, document}
      {:error, _reason} -> :error
    end
  end

  defp drawn(document, attrs, url) do
    case Whiteboard.svg(document) do
      {:ok, svg} -> [picture(svg, attrs), address(url)]
      :error -> sorry(attrs, url)
    end
  end

  # A data URI rather than inline markup: the renderer's tree is HTML, and Floki
  # lowercases attribute names — `viewBox` would not survive the round trip.
  defp picture(svg, attrs) do
    src = "data:image/svg+xml;base64," <> Base.encode64(svg)

    {"img",
     [
       {"class", "mirror-whiteboard"},
       {"src", src},
       {"alt", "#{kind(attrs)}, drawn from its document"}
     ], []}
  end

  defp sorry(attrs, url) do
    [
      Nodes.notice(
        "The mirror could not draw this #{String.downcase(kind(attrs))}. " <>
          "It is a canvas Confluence paints itself; open it there to see it as its authors do."
      ),
      address(url)
    ]
  end

  defp address(url),
    do: {"p", [], [{"a", [{"href", url}, {"class", "mirror-dynamic-link"}], [url]}]}

  # A marker carries the macro it came from, which is the only place the kind is
  # recorded: the page writes one name for each embed.
  defp kind(attrs), do: Map.get(@kinds, Map.get(attrs, "macro"), "Embedded content")

  defp url(attrs) do
    case attrs |> Map.get("url", "") |> String.trim() do
      "" -> nil
      url -> url
    end
  end
end
