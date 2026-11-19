defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.NativeEmbed do
  @moduledoc """
  *Whiteboards, Databases and Slides*: drawn when the mirror can, linked when it
  cannot.

      <div class="mirror-macro" data-macro="native-embed:whiteboard"
           data-url="https://site/wiki/spaces/MFS/whiteboard/28344336"></div>

  A whiteboard's export view carries only an unknown-macro placeholder, but the
  board's document is readable over GraphQL and holds the nodes, their geometry
  and their words — so a whiteboard is drawn as a still picture of itself
  (`Sync.Whiteboard`). A database's columns and rows are readable too, so it is
  drawn as a still of its table — bounded, and never as the view the page
  embeds: the API withholds a view's filters, sorting, grouping and hidden
  columns. A database restricted more narrowly than the page is not drawn at
  all; it is named and linked.

  A slide deck is a canvas Confluence paints in its own app: the graph's
  `ConfluenceSlide` node carries the deck's title, version and links and no body,
  and no export endpoint returns one. So a deck is drawn as its card — the name,
  the version it was read at, the reason there is no picture, and the way to the
  deck — instead of a sentence that claims a drawing that does not exist.

  Anything that stops the drawing — no address, a fetch that fails, a document
  version this mirror does not know, a board with nothing in it — is answered
  with an apology and a link to the real thing, never with a silently empty box.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes, Registry}
  alias ConfluencePhxMirror.Sync.Whiteboard

  @kinds %{
    "native-embed:database" => "Database",
    "native-embed:slide" => "Slides",
    "native-embed:whiteboard" => "Whiteboard"
  }

  @impl true
  def render(attrs, %Context{} = context) do
    attrs = canonical(attrs)

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

  # A marker carries the spelling the page stored; the registry knows which name
  # that is. Everything below dispatches on the canonical one.
  defp canonical(attrs) do
    Map.update(attrs, "macro", "", &Registry.canonical(String.downcase(&1)))
  end

  # A whiteboard is drawn; anything else is named and linked.
  defp contents(%{"macro" => "native-embed:whiteboard"} = attrs, url, context) do
    case board(context, url) do
      {:ok, document} -> drawn(document, attrs, url)
      :error -> sorry(attrs, url)
    end
  end

  # A database's columns and rows are readable, so the embed is drawn as a still
  # of the whole table. It is not the view a page embeds: the API withholds a
  # view's filters, sorting, grouping and hidden columns, and `/entries` is
  # database-wide. An empty column list is how the port says the rows may not be
  # drawn — a restricted database, or one that could not be read — and then the
  # embed is named and linked, never left as an empty table that pretends the
  # database holds nothing.
  defp contents(%{"macro" => "native-embed:database"} = attrs, url, context) do
    case lookup(context, url, :database) do
      {:ok, %{"fields" => [_ | _]} = table} ->
        [table_figure(table, attrs, url, context)]

      {:ok, %{"title" => title}} when is_binary(title) and title != "" ->
        [titled("Database", title), address(attrs, url)]

      _unreadable ->
        [plain("Database"), address(attrs, url)]
    end
  end

  # A deck is drawn as what the site actually publishes for it: the record. A
  # deck is a canvas Confluence paints in its own app — the graph's
  # `ConfluenceSlide` node has a title, a version and links and no body, and no
  # export endpoint returns one — so the card carries the deck's name and
  # version, says why there is no picture, and links the deck. A record that
  # cannot be read is named and linked like a database's.
  defp contents(%{"macro" => "native-embed:slide"} = attrs, url, context) do
    case lookup(context, url, :slide) do
      {:ok, %{"title" => title} = record} when is_binary(title) and title != "" ->
        [deck_card(record, attrs, url)]

      _unreadable ->
        [plain("Slides"), address(attrs, url)]
    end
  end

  defp contents(attrs, url, _context) do
    [Nodes.notice("#{kind(attrs)} — drawn in Confluence; open it there."), address(attrs, url)]
  end

  # A deck's card: what the site publishes, drawn as a card rather than as an
  # apology. The version is the record's own, so a reader can tell whether the
  # copy moved with the deck.
  defp deck_card(record, attrs, url) do
    {"figure", [{"class", "mirror-figure mirror-slides"}],
     [
       {"div", [{"class", "mirror-slide-deck"}],
        [
          {"p", [{"class", "mirror-slide-deck-kind"}], ["Slides"]},
          {"p", [{"class", "mirror-slide-deck-title"}], [record["title"]]},
          version_line(record),
          Nodes.notice(
            "A deck is a canvas Confluence paints in its own app, and the site " <>
              "publishes no slide document for it, so the mirror cannot draw the slides. " <>
              "The deck itself is one click away."
          )
        ]},
       caption(attrs, url)
     ]}
  end

  defp version_line(%{"latestVersion" => %{"number" => number}}) when is_integer(number) do
    {"p", [{"class", "mirror-dynamic-meta"}], ["Version #{number} when it was read"]}
  end

  defp version_line(_unversioned), do: {"span", [], []}

  defp titled(kind, title) do
    Nodes.notice("#{kind} “#{title}” — drawn in Confluence; the mirror links to it.")
  end

  defp plain(kind), do: Nodes.notice("#{kind} — drawn in Confluence; open it there.")

  defp lookup(context, url, :database), do: context.source.database(context.page, url)
  defp lookup(context, url, :slide), do: context.source.slide(context.page, url)

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

  # A table is a still like a board is: readable at a glance, and bounded. The
  # caption names the database and links it; the rows are the first a still
  # draws, and the rest is said out loud rather than silently dropped.
  defp table_figure(%{"fields" => fields, "entries" => entries} = table, attrs, url, context) do
    {"figure", [{"class", "mirror-figure mirror-database"}],
     [caption(attrs, url), table_node(fields, entries, context)] ++ truncation(table)}
  end

  defp table_node(fields, entries, context) do
    {"div", [{"class", "mirror-table-scroll"}],
     [
       {"table", [{"class", "mirror-database-table"}],
        [
          {"thead", [], [{"tr", [], Enum.map(fields, &{"th", [], [&1["name"] || ""]})}]},
          {"tbody", [], Enum.map(entries, &row(fields, &1, context))}
        ]}
     ]}
  end

  defp row(fields, %{"values" => values}, context) do
    {"tr", [],
     Enum.map(fields, fn field -> {"td", [], cell(Map.get(values, field["id"]), context)} end)}
  end

  # A user cell stores account ids. An id is not a name a reader can use, so it is
  # resolved through the port; an account nobody can name is left out rather than
  # printed. The name is the link the rest of the mirror writes for a person,
  # and it is a link only where `/people/:account_id` answers.
  defp cell(%{"type" => "user", "value" => value}, context) when not is_nil(value) do
    value
    |> List.wrap()
    |> Enum.map(&person_node(&1, context))
    |> Enum.reject(&is_nil/1)
    |> Enum.intersperse(", ")
  end

  defp cell(%{"plain" => text}, _context) when is_binary(text), do: [text]
  defp cell(%{"value" => value}, _context) when is_binary(value), do: [value]
  defp cell(%{"value" => value}, _context) when is_number(value), do: [to_string(value)]

  defp cell(%{"value" => value}, _context) when is_boolean(value),
    do: [if(value, do: "Yes", else: "No")]

  # A select stores its options as `%{"id", "label"}` — the label is what the
  # cell showed in Confluence, and it is a link when pages here carry it.
  defp cell(%{"value" => values}, context) when is_list(values) do
    values
    |> Enum.map(&label_node(&1, context))
    |> Enum.reject(&is_nil/1)
    |> Enum.intersperse(", ")
  end

  defp cell(_empty, _context), do: []

  defp person_node(account, context) do
    id = account_id(account)

    with true <- is_binary(id) and id != "",
         name when is_binary(name) <- context.source.person(context.page, id) do
      Nodes.person_name(name, if(context.source.person_page?(context.page, id), do: id))
    else
      _unknown -> nil
    end
  end

  defp account_id(%{"accountId" => id}) when is_binary(id), do: id
  defp account_id(id) when is_binary(id), do: id
  defp account_id(_unknown), do: nil

  defp label_node(%{"label" => label}, context), do: label_node(label, context)

  defp label_node(label, context) when is_binary(label) and label != "" do
    if context.source.label?(context.page, label), do: Nodes.label_link(label), else: label
  end

  defp label_node(_unknown, _context), do: nil

  defp truncation(%{"truncated" => true}) do
    [
      Nodes.notice(
        "The table holds more rows than a still draws; " <>
          "open the database in Confluence for all of it."
      )
    ]
  end

  defp truncation(_complete), do: []

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
