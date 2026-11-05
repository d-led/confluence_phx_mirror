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

  # A database is a live view: the mirror can read its record, not its rows. So
  # it names the database it was given instead of guessing, and says the one
  # true thing about a view — open it where it lives.
  defp contents(%{"macro" => "native-embed:database"} = attrs, url, context) do
    [record(context, url), address(attrs, url)]
  end

  defp contents(attrs, url, _context) do
    [Nodes.notice("#{kind(attrs)} — drawn in Confluence; open it there."), address(attrs, url)]
  end

  defp record(context, url) do
    case context.source.database(context.page, url) do
      {:ok, %{"title" => title}} when is_binary(title) and title != "" ->
        Nodes.notice("Database “#{title}” — a live view; the mirror links to it.")

      _unreadable ->
        Nodes.notice("Database — drawn in Confluence; open it there.")
    end
  end

  defp board(context, url) do
    case context.source.whiteboard(context.page, url) do
      {:ok, document} -> {:ok, document}
      {:error, _reason} -> :error
    end
  end

  defp drawn(document, attrs, url) do
    case Whiteboard.svg(document) do
      {:ok, svg} -> [figure(svg, attrs, url)]
      :error -> sorry(attrs, url)
    end
  end

  # A board is a canvas, and a canvas is wide: at the width of a column of prose
  # the drawing is a thumbnail and its words are unreadable. So the picture is a
  # control — a reader who wants to read it opens it over the page, where
  # `assets/js/whiteboard.js` zooms, pans and saves it.
  defp figure(svg, attrs, url) do
    {"figure", [{"class", "mirror-figure"}], [picture(svg, attrs), caption(attrs, url)]}
  end

  # A data URI rather than inline markup: the renderer's tree is HTML, and Floki
  # lowercases attribute names — `viewBox` would not survive the round trip.
  defp picture(svg, attrs) do
    {"button",
     [
       {"type", "button"},
       {"class", "mirror-figure-open"},
       {"data-whiteboard-zoom", ""},
       {"data-whiteboard-name", name(attrs)},
       {"aria-label", "Open the #{String.downcase(kind(attrs))} full screen"}
     ],
     [
       {"img",
        [
          {"class", "mirror-whiteboard"},
          {"src", "data:image/svg+xml;base64," <> Base.encode64(svg)},
          {"alt", "#{kind(attrs)}, drawn from its document"}
        ], []}
     ]}
  end

  # What a saved copy is called: the board's own number, so two boards downloaded
  # from one page do not fight over a filename.
  defp name(attrs) do
    case attrs |> Map.get("url", "") |> String.split("/") |> Enum.reject(&(&1 == "")) do
      [] -> "whiteboard.svg"
      parts -> "whiteboard-#{List.last(parts)}.svg"
    end
  end

  defp sorry(attrs, url) do
    [
      Nodes.notice(
        "The mirror could not draw this #{String.downcase(kind(attrs))}. " <>
          "It is a canvas Confluence paints itself; open it there to see it as its authors do."
      ),
      address(attrs, url)
    ]
  end

  # A caption, not a citation: the address is long and says nothing a reader
  # wants to read, and the drawing above it already carries the content. The
  # link still goes where the words say it does.
  defp caption(attrs, url) do
    {"figcaption", [{"class", "mirror-embed-source"}], [source_link(attrs, url)]}
  end

  defp address(attrs, url) do
    {"p", [{"class", "mirror-embed-source"}], [source_link(attrs, url)]}
  end

  defp source_link(attrs, url) do
    {"a", [{"href", url}, {"class", "mirror-dynamic-link"}], ["#{kind(attrs)} in Confluence"]}
  end

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
