defmodule ConfluencePhxMirrorWeb.SearchLive do
  @moduledoc """
  Google-like search, with an advanced panel for the questions a plain box
  cannot express.

  The quick path is the pill bar: space, content type, time window and labels,
  the way Confluence does it. Behind "Advanced" sits the widget-assisted panel:

    * the four text boxes Confluence offers — all of these words, this exact
      phrase, any of these words, none of these words — which are composed into
      the one query the text engine reads;
    * several spaces at once, a contributor picked from the people the mirror
      has seen, a last-modified date range and an explicit sort.

  Every control is a real button or input with a 40px tap target, so the row
  works on touch as well as with a mouse. The raw CQL is never exposed;
  `Mirror.Search.Filters` turns the widgets into the mirror's own query, and the
  whole state of a search lives in the URL so it can be shared.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.MirrorComponents

  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Catalog
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Search

  # How many results a reader page shows; deployment sized (CM_SEARCH_PAGE_SIZE).
  defp page_size, do: Application.get_env(:confluence_phx_mirror, :search, [])[:page_size] || 30

  @debounce 220

  # How many spaces the space menus list. The directory is `/spaces`.
  @space_window 25
  @label_window 200
  @author_window 100
  @label_strip 12
  @type_options [{"page", "Pages and live docs"}, {"blogpost", "Blog posts"}]
  @sort_options [{"", "Best match"}, {"newest", "Newest first"}, {"oldest", "Oldest first"}]
  @window_options [
    {"", "Anytime"},
    {"today", "Today"},
    {"yesterday", "Yesterday"},
    {"7d", "Past 7 days"},
    {"30d", "Past 30 days"},
    {"365d", "Past year"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    # The space menus are drawn twice on this screen (the pill bar and the
    # advanced panel), so a mirror with a thousand spaces would send a thousand
    # entries twice with every search. They take a window; a space's own catalog
    # filters inside that space.
    spaces = Mirror.list_spaces(limit: @space_window)
    scope = socket.assigns.current_scope
    label_catalog = Catalog.label_counts(scope, limit: @label_window)
    label_highlights = Catalog.label_counts(scope, limit: @label_strip, order: :popular)

    {:ok,
     assign(socket,
       q: "",
       phrase: "",
       any: "",
       none: "",
       space: "",
       spaces_filter: "",
       creator: "",
       from: "",
       to: "",
       sort: "",
       advanced?: nil,
       labels: "",
       types: "",
       updated: "",
       label_query: "",
       space_query: "",
       people_query: "",
       open_menu: nil,
       results: [],
       terms: [],
       error: nil,
       searched?: false,
       chips: [],
       page_title: "Search",
       spaces: spaces,
       spaces_more?: Mirror.stats().spaces > length(spaces),
       authors: Mirror.authors(limit: @author_window),
       label_catalog: label_catalog,
       label_highlights: label_highlights,
       recent_pages: Mirror.recent_pages(6),
       type_options: @type_options,
       window_options: @window_options,
       sort_options: @sort_options,
       form: to_form(empty_params(), as: :search),
       debounce: @debounce
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = take_filters(params)

    {results, terms, error} =
      case Search.structured(filters, limit: page_size(), sort: sort_of(filters["sort"])) do
        {:ok, results, terms} ->
          {Authorization.readable_results(socket.assigns.current_scope, results), terms, nil}

        {:error, message} ->
          {[], [], message}
      end

    {:noreply,
     assign(socket,
       q: filters["q"],
       phrase: filters["phrase"],
       any: filters["any"],
       none: filters["none"],
       space: filters["space"],
       spaces_filter: filters["spaces"],
       creator: filters["creator"],
       from: filters["from"],
       to: filters["to"],
       sort: filters["sort"],
       advanced?: panel_state(socket.assigns.advanced?, filters),
       labels: filters["labels"],
       types: filters["types"],
       updated: filters["updated"],
       results: results,
       terms: terms,
       error: error,
       searched?: Enum.any?(filters, fn {_key, value} -> value != "" end),
       page_title: search_title(filters),
       chips: chips(filters),
       form: to_form(Map.merge(empty_params(), filters), as: :search)
     )}
  end

  @impl true
  def handle_event("search", %{"search" => params}, socket) do
    q = params |> Map.get("q", "") |> to_string() |> String.trim()
    {:noreply, patch(socket, Map.put(current_filters(socket), "q", q))}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/search")}
  end

  # The advanced panel submits every widget at once; a blank control simply
  # stops filtering, so the URL always describes what is on screen.
  def handle_event("advanced", %{"search" => params}, socket) do
    filters =
      current_filters(socket)
      |> Map.merge(%{
        "phrase" => clean(params["phrase"]),
        "any" => clean(params["any"]),
        "none" => clean(params["none"]),
        "from" => clean(params["from"]),
        "to" => clean(params["to"])
      })

    {:noreply, patch(socket, filters)}
  end

  def handle_event("set_creator", %{"creator" => value}, socket) do
    creator = if value == socket.assigns.creator, do: "", else: value

    {:noreply,
     socket
     |> assign(:open_menu, nil)
     |> patch(Map.put(current_filters(socket), "creator", creator))}
  end

  def handle_event("toggle_menu", %{"menu" => menu}, socket) do
    open = if socket.assigns.open_menu == menu, do: nil, else: menu
    {:noreply, assign(socket, :open_menu, open)}
  end

  def handle_event("close_menu", _params, socket) do
    {:noreply, assign(socket, :open_menu, nil)}
  end

  def handle_event("space_query", %{"space" => value}, socket) do
    {:noreply, assign(socket, :space_query, clean(value))}
  end

  def handle_event("people_query", %{"people" => value}, socket) do
    {:noreply, assign(socket, :people_query, clean(value))}
  end

  def handle_event("clear_labels", _params, socket) do
    {:noreply, patch(socket, Map.put(current_filters(socket), "labels", ""))}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :advanced?, not (socket.assigns.advanced? || false))}
  end

  def handle_event("set_sort", %{"sort" => value}, socket) do
    {:noreply, patch(socket, Map.put(current_filters(socket), "sort", clean(value)))}
  end

  def handle_event("set_space", %{"space" => value}, socket) do
    space = if value == socket.assigns.space, do: "", else: value

    {:noreply,
     socket |> assign(:open_menu, nil) |> patch(Map.put(current_filters(socket), "space", space))}
  end

  def handle_event("toggle_type", %{"type" => value}, socket) do
    types = toggle(label_values(socket.assigns.types), value)

    {:noreply, patch(socket, Map.put(current_filters(socket), "types", Enum.join(types, ",")))}
  end

  def handle_event("set_updated", %{"updated" => value}, socket) do
    updated = if value == socket.assigns.updated, do: "", else: value

    {:noreply,
     socket
     |> assign(:open_menu, nil)
     |> patch(Map.put(current_filters(socket), "updated", updated))}
  end

  def handle_event("toggle_label", %{"label" => label}, socket) do
    labels = toggle(label_values(socket.assigns.labels), label)

    {:noreply, patch(socket, Map.put(current_filters(socket), "labels", Enum.join(labels, ",")))}
  end

  def handle_event("label_query", %{"label" => value}, socket) do
    {:noreply, assign(socket, :label_query, value |> to_string() |> String.trim())}
  end

  def handle_event("add_label", %{"label" => value}, socket) do
    case normalise_label(value) do
      "" ->
        {:noreply, socket}

      label ->
        labels = Enum.uniq(label_values(socket.assigns.labels) ++ [label])

        socket =
          socket
          |> assign(:label_query, "")
          |> patch(Map.put(current_filters(socket), "labels", Enum.join(labels, ",")))

        {:noreply, socket}
    end
  end

  defp empty_params do
    %{
      "q" => "",
      "phrase" => "",
      "any" => "",
      "none" => "",
      "space" => "",
      "spaces" => "",
      "creator" => "",
      "from" => "",
      "to" => "",
      "sort" => "",
      "labels" => "",
      "types" => "",
      "updated" => ""
    }
  end

  defp current_filters(socket) do
    %{
      "q" => socket.assigns.q,
      "phrase" => socket.assigns.phrase,
      "any" => socket.assigns.any,
      "none" => socket.assigns.none,
      "space" => socket.assigns.space,
      "spaces" => socket.assigns.spaces_filter,
      "creator" => socket.assigns.creator,
      "from" => socket.assigns.from,
      "to" => socket.assigns.to,
      "sort" => socket.assigns.sort,
      "labels" => socket.assigns.labels,
      "types" => socket.assigns.types,
      "updated" => socket.assigns.updated
    }
  end

  defp take_filters(params) do
    %{
      "q" => clean(params["q"]),
      "phrase" => clean(params["phrase"]),
      "any" => clean(params["any"]),
      "none" => clean(params["none"]),
      "space" => clean(params["space"]),
      "spaces" => (params["spaces"] || "") |> space_values() |> Enum.join(","),
      "creator" => clean(params["creator"]),
      "from" => clean(params["from"]),
      "to" => clean(params["to"]),
      "sort" => clean(params["sort"]),
      "labels" => (params["labels"] || params["label"]) |> label_values() |> Enum.join(","),
      "types" => (params["types"] || params["type"]) |> label_values() |> Enum.join(","),
      "updated" => clean(params["updated"])
    }
  end

  # The panel is the reader's choice once they have made it: typing into any of
  # its fields patches the URL, and a shared link that already carries advanced
  # filters opens it on the first load.
  defp panel_state(nil, filters), do: advanced?(filters)
  defp panel_state(open?, _filters), do: open?

  # The advanced panel is open whenever something in it is filtering, so a
  # shared link opens with its controls visible.
  defp advanced?(filters) do
    Enum.any?(~w(phrase any none spaces creator from to sort), &(filters[&1] != ""))
  end

  defp result_count([]), do: "No results"
  defp result_count([_one]), do: "1 result"
  defp result_count(results), do: "#{length(results)} results"

  defp search_title(%{"q" => ""}), do: "Search"
  defp search_title(%{"q" => q}), do: "Search · #{q}"
  defp search_title(_filters), do: "Search"

  defp sort_of("newest"), do: :newest
  defp sort_of("oldest"), do: :oldest
  defp sort_of(_sort), do: :relevance

  defp clean(nil), do: ""
  defp clean(value), do: value |> to_string() |> String.trim()

  defp patch(socket, filters) do
    push_patch(socket, to: search_path(filters), replace: true)
  end

  defp search_path(filters) do
    query =
      filters
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Enum.sort()
      |> URI.encode_query()

    if query == "", do: ~p"/search", else: "/search?" <> query
  end

  defp chips(filters) do
    base = [
      {"q", filters["q"]},
      {"phrase", filters["phrase"]},
      {"any", filters["any"]},
      {"none", filters["none"]},
      {"space", filters["space"]},
      {"spaces", filters["spaces"]},
      {"creator", filters["creator"]},
      {"from", filters["from"]},
      {"to", filters["to"]},
      {"sort", filters["sort"]},
      {"updated", filters["updated"]}
    ]

    types = Enum.map(label_values(filters["types"]), &{"types", &1})
    labels = Enum.map(label_values(filters["labels"]), &{"labels", &1})

    (base ++ types ++ labels)
    |> Enum.reject(fn {_key, value} -> value in [nil, "", "relevance"] end)
    |> Enum.map(fn {key, value} ->
      %{
        key: key,
        label: chip_label(key, value),
        path: search_path(remove(filters, key, value))
      }
    end)
  end

  defp remove(filters, "types", value) do
    types = filters["types"] |> label_values() |> List.delete(value)
    Map.put(filters, "types", Enum.join(types, ","))
  end

  defp remove(filters, key, value) when key in ["types", "labels"] do
    Map.put(filters, key, Enum.join(label_values(filters[key]) -- [value], ","))
  end

  defp remove(filters, key, _value), do: Map.put(filters, key, "")

  defp chip_label("q", value), do: value
  defp chip_label("phrase", value), do: "Phrase: #{value}"
  defp chip_label("any", value), do: "Any of: #{value}"
  defp chip_label("none", value), do: "None of: #{value}"
  defp chip_label("spaces", value), do: "Spaces: #{String.replace(value, ",", ", ")}"
  defp chip_label("creator", value), do: "By: #{value}"
  defp chip_label("from", value), do: "Modified after #{value}"
  defp chip_label("to", value), do: "Modified before #{value}"
  defp chip_label("sort", "newest"), do: "Sort: newest first"
  defp chip_label("sort", "oldest"), do: "Sort: oldest first"
  defp chip_label("space", value), do: "Space: #{value}"
  defp chip_label("labels", value), do: "Label: #{value}"
  defp chip_label("types", "page"), do: "Type: pages"
  defp chip_label("types", "blogpost"), do: "Type: blog posts"
  defp chip_label("types", value), do: "Type: #{value}"
  defp chip_label("updated", "7d"), do: "Past 7 days"
  defp chip_label("updated", "30d"), do: "Past 30 days"
  defp chip_label("updated", "90d"), do: "Past 90 days"
  defp chip_label("updated", "365d"), do: "Past year"
  defp chip_label("updated", value), do: "Updated: #{value}"
  defp chip_label(key, value), do: "#{key}: #{value}"

  defp label_values(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&normalise_label/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Space keys are matched as Confluence spells them, so they are only trimmed.
  defp space_values(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(&String.split(to_string(&1), ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalise_label(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, "-")
  end

  defp toggle(list, value) do
    if value in list, do: List.delete(list, value), else: list ++ [value]
  end

  defp space_label("", _spaces), do: "All spaces"

  defp space_label(key, spaces) do
    case Enum.find(spaces, &(&1.key == key)) do
      nil -> "Space: #{key}"
      space -> space.name
    end
  end

  defp space_summary("", _spaces), do: "Space"
  defp space_summary(key, spaces), do: space_label(key, spaces)

  defp creator_summary(""), do: "Edited or created by"
  defp creator_summary(name), do: name

  defp type_summary(types) do
    case label_values(types) do
      [] -> "Type"
      ["page"] -> "Type: Pages and live docs"
      ["blogpost"] -> "Type: Blog posts"
      several -> "Type: #{length(several)} kinds"
    end
  end

  defp labels_summary(labels) do
    case label_values(labels) do
      [] -> "Labels"
      [one] -> "Label: #{one}"
      several -> "#{length(several)} labels"
    end
  end

  defp matching_spaces(spaces, ""), do: spaces

  defp matching_spaces(spaces, query) do
    query = String.downcase(query)
    Enum.filter(spaces, &String.contains?(String.downcase(&1.name <> " " <> &1.key), query))
  end

  defp matching_authors(authors, ""), do: authors

  defp matching_authors(authors, query) do
    query = String.downcase(query)
    Enum.filter(authors, &String.contains?(String.downcase(&1.name), query))
  end

  defp matching_labels(catalog, ""), do: catalog

  defp matching_labels(catalog, query) do
    query = normalise_label(query)
    Enum.filter(catalog, fn %{name: name} -> String.contains?(name, query) end)
  end

  defp updated_label(value) do
    Enum.find_value(@window_options, "Any time", fn
      {^value, label} -> label
      _ -> nil
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      spaces={@spaces}
      last_sync_run={@last_sync_run}
      mirror_name={@mirror_name}
      mirror_source={@mirror_source}
      search_query={@q}
      page_title={@page_title}
      sidebar?={false}
    >
      <div class="mx-auto max-w-3xl">
        <h1 class="sr-only">Search the mirror</h1>
        <.form
          for={@form}
          id="search-form"
          phx-change="search"
          phx-submit="search"
          class="mt-2 sm:mt-6"
        >
          <label class="input input-lg w-full">
            <.icon name="hero-magnifying-glass" class="size-5 opacity-50" />
            <%!-- A bare input: the <.input> component wraps its control in a
            fieldset div, which then is the flex child and never grows. --%>
            <input
              type="search"
              name={@form[:q].name}
              value={@form[:q].value}
              id={@form[:q].id}
              aria-label="Search"
              placeholder="Search pages, decisions, people…"
              autocomplete="off"
              autofocus
              phx-debounce={@debounce}
              class="grow [&::-webkit-search-cancel-button]:appearance-none [&::-webkit-search-decoration]:appearance-none"
            />
            <%!-- One clear affordance, ours: the browser draws its own cancel
            button for type="search", which sat next to this one. --%>
            <button
              :if={@q != ""}
              type="button"
              phx-click="clear"
              class="btn btn-ghost btn-sm btn-square"
              aria-label="Clear search"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </label>
        </.form>

        <.filter_bar
          space={@space}
          spaces={@spaces}
          spaces_more?={@spaces_more?}
          space_query={@space_query}
          creator={@creator}
          authors={@authors}
          people_query={@people_query}
          types={@types}
          type_options={@type_options}
          updated={@updated}
          window_options={@window_options}
          labels={@labels}
          label_query={@label_query}
          label_catalog={@label_catalog}
          advanced?={@advanced?}
          sort={@sort}
          sort_options={@sort_options}
          open_menu={@open_menu}
        />

        <.advanced_panel
          :if={@advanced?}
          q={@q}
          phrase={@phrase}
          any={@any}
          none={@none}
          spaces_filter={@spaces_filter}
          spaces={@spaces}
          spaces_more?={@spaces_more?}
          creator={@creator}
          authors={@authors}
          from={@from}
          to={@to}
          updated={@updated}
          window_options={@window_options}
        />

        <div :if={@chips != []} class="mt-2 flex flex-wrap items-center gap-1">
          <a
            :for={chip <- @chips}
            href={chip.path}
            class="badge badge-primary badge-outline badge-md gap-1"
            title={"Remove #{chip.label}"}
          >
            {chip.label}
            <.icon name="hero-x-mark" class="size-3" />
          </a>
          <a :if={length(@chips) > 1} href={~p"/search"} class="link link-hover ml-1 text-xs">
            Clear all
          </a>
        </div>

        <div :if={@error} class="mt-4 alert alert-error alert-soft text-sm">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          <span>{@error}</span>
        </div>

        <p
          :if={@searched? and is_nil(@error)}
          aria-live="polite"
          class="mt-6 text-xs text-base-content/70"
        >
          {result_count(@results)}
        </p>

        <div :if={@results != []} class="mt-2 space-y-4">
          <.search_hit :for={result <- @results} result={result} terms={@terms} />
        </div>

        <.empty_state
          :if={@searched? and @results == [] and is_nil(@error)}
          icon="hero-magnifying-glass"
          title="No results"
          body="Try fewer words, a different space, or remove a filter."
        />

        <%= if not @searched? do %>
          <section class="mt-10">
            <h2 class="mb-3 text-[11px] font-semibold uppercase tracking-wider text-base-content/70">
              Recently updated
            </h2>
            <div class="grid gap-2 sm:grid-cols-2">
              <.link
                :for={page <- @recent_pages}
                navigate={
                  ConfluencePhxMirror.Mirror.URLs.page_path(
                    page.space.key,
                    page.confluence_id,
                    page.slug
                  )
                }
                class="group flex items-center gap-2 rounded-lg border border-base-300/60 bg-base-100 px-3 py-2 transition hover:border-primary/40 hover:bg-base-200/40"
              >
                <.icon name="hero-document-text" class="size-4 shrink-0 text-base-content/70" />
                <span class="min-w-0 flex-1 truncate text-sm group-hover:text-primary">{page.title}</span>
                <span class="shrink-0 text-[10px] text-base-content/70">{page.space.key}</span>
              </.link>
            </div>
          </section>

          <section :if={@label_highlights != []} class="mt-8">
            <h2 class="mb-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/70">
              Browse by label
            </h2>
            <div class="flex flex-wrap gap-1.5">
              <a
                :for={%{name: label, pages: count} <- @label_highlights}
                href={~p"/labels/#{label}"}
                class="badge badge-outline badge-sm"
              >
                {label} <span class="ml-0.5 text-base-content/70">{count}</span>
              </a>
            </div>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :space, :string, required: true
  attr :spaces, :list, required: true
  attr :spaces_more?, :boolean, default: false
  attr :space_query, :string, default: ""
  attr :creator, :string, required: true
  attr :authors, :list, required: true
  attr :people_query, :string, default: ""
  attr :types, :string, required: true
  attr :type_options, :list, required: true
  attr :updated, :string, required: true
  attr :window_options, :list, required: true
  attr :labels, :string, required: true
  attr :label_query, :string, required: true
  attr :label_catalog, :list, required: true
  attr :advanced?, :boolean, default: false
  attr :sort, :string, default: ""
  attr :sort_options, :list, required: true
  attr :open_menu, :any, default: nil

  defp filter_bar(assigns) do
    ~H"""
    <div class="mt-3 flex min-w-0 flex-wrap items-center gap-2" id="search-filters">
      <.filter_menu
        id="space-filter"
        open?={@open_menu == "space-filter"}
        icon="hero-rectangle-stack"
        label={space_summary(@space, @spaces)}
      >
        <form id="space-form" phx-change="space_query" phx-submit="set_space">
          <input
            type="text"
            name="space"
            value={@space_query}
            placeholder="Find a space"
            autocomplete="off"
            phx-debounce="150"
            phx-mounted={JS.focus()}
            class="input input-sm w-full"
          />
        </form>
        <ul class="menu menu-sm w-full p-0">
          <li :for={space <- matching_spaces(@spaces, @space_query)}>
            <button
              type="button"
              phx-click="set_space"
              phx-value-space={space.key}
              class={space.key == @space && "menu-active"}
            >
              <span class="truncate">{space.name}</span>
              <span class="badge badge-ghost badge-xs">{space.key}</span>
            </button>
          </li>
          <li :if={@space_query == ""}>
            <button type="button" phx-click="set_space" phx-value-space="">
              Clear filter
            </button>
          </li>
        </ul>
      </.filter_menu>

      <.filter_menu
        id="creator-filter"
        open?={@open_menu == "creator-filter"}
        icon="hero-user-circle"
        label={creator_summary(@creator)}
      >
        <form id="people-form" phx-change="people_query" phx-submit="set_creator">
          <input
            type="text"
            name="people"
            value={@people_query}
            placeholder="Find a person"
            autocomplete="off"
            phx-debounce="150"
            phx-mounted={JS.focus()}
            class="input input-sm w-full"
          />
        </form>
        <ul class="menu menu-sm w-full p-0">
          <li :for={author <- matching_authors(@authors, @people_query)}>
            <button
              type="button"
              phx-click="set_creator"
              phx-value-creator={author.name}
              class={author.name == @creator && "menu-active"}
            >
              <span class="truncate">{author.name}</span>
              <span class="badge badge-ghost badge-xs">{author.pages}</span>
            </button>
          </li>
          <li :if={@people_query == ""}>
            <button type="button" phx-click="set_creator" phx-value-creator="">
              Clear filter
            </button>
          </li>
        </ul>
      </.filter_menu>

      <.filter_menu
        id="updated-filter"
        open?={@open_menu == "updated-filter"}
        icon="hero-clock"
        label={"Last updated: #{updated_label(@updated)}"}
      >
        <ul class="menu menu-sm w-full p-0">
          <li :for={{value, label} <- @window_options}>
            <button
              type="button"
              phx-click="set_updated"
              phx-value-updated={value}
              class={value == @updated && "menu-active"}
            >
              {label}
            </button>
          </li>
        </ul>
      </.filter_menu>

      <.filter_menu
        id="type-filter"
        open?={@open_menu == "type-filter"}
        icon="hero-document-text"
        label={type_summary(@types)}
      >
        <ul class="menu menu-sm w-full p-0">
          <li :for={{value, label} <- @type_options}>
            <button
              type="button"
              phx-click="toggle_type"
              phx-value-type={value}
              aria-pressed={value in label_values(@types)}
              class={value in label_values(@types) && "menu-active"}
            >
              <.icon
                name={if value in label_values(@types), do: "hero-check", else: "hero-plus"}
                class="size-4 text-primary"
              />
              <span class="truncate">{label}</span>
            </button>
          </li>
        </ul>
      </.filter_menu>

      <.filter_menu
        id="labels-filter"
        open?={@open_menu == "labels-filter"}
        icon="hero-tag"
        label={labels_summary(@labels)}
      >
        <form id="label-form" phx-change="label_query" phx-submit="add_label">
          <input
            type="text"
            name="label"
            value={@label_query}
            placeholder="Find a label"
            autocomplete="off"
            phx-debounce="150"
            phx-mounted={JS.focus()}
            class="input input-sm w-full"
          />
        </form>
        <ul class="menu menu-sm w-full p-0">
          <li :for={%{name: name, pages: count} <- matching_labels(@label_catalog, @label_query)}>
            <button
              type="button"
              phx-click="toggle_label"
              phx-value-label={name}
              class={name in label_values(@labels) && "menu-active"}
            >
              <.icon
                name={if name in label_values(@labels), do: "hero-check", else: "hero-plus"}
                class="size-4 text-primary"
              />
              <span class="truncate">{name}</span>
              <span class="badge badge-ghost badge-xs">{count}</span>
            </button>
          </li>
          <li :if={matching_labels(@label_catalog, @label_query) == []}>
            <button type="button" disabled>Start typing to search for a label</button>
          </li>
          <li :if={@labels != ""}>
            <button type="button" phx-click="clear_labels">Clear filter</button>
          </li>
        </ul>
      </.filter_menu>

      <button
        type="button"
        id="advanced-toggle"
        phx-click="toggle_advanced"
        aria-expanded={@advanced?}
        class="btn btn-sm gap-1.5 font-normal"
      >
        <.icon name={if @advanced?, do: "hero-minus", else: "hero-plus"} class="size-4" />
        {if @advanced?, do: "Hide filters", else: "More filters"}
      </button>

      <form id="sort-form" phx-change="set_sort" class="ml-auto flex items-center gap-2">
        <label class="label text-xs" for="sort-filter">Sort</label>
        <select id="sort-filter" name="sort" class="select select-sm">
          <option :for={{value, label} <- @sort_options} value={value} selected={value == @sort}>
            {label}
          </option>
        </select>
      </form>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :open?, :boolean, default: false
  slot :inner_block, required: true

  # One dropdown per filter, the way Confluence's search bar works: the button
  # says which filter it is and what is currently chosen, the menu holds the
  # options (or a "Find a …" box for the long lists).
  #
  # The open state is the server's, not the browser's: daisyUI's dropdown also
  # opens on :focus-within, which would leave a menu on screen after the reader
  # picked something and LiveView closed it, so the closed state is spelled out
  # with `dropdown-close`.
  defp filter_menu(assigns) do
    ~H"""
    <div
      class={["dropdown", if(@open?, do: "dropdown-open", else: "dropdown-close")]}
      id={@id}
      phx-click-away={@open? && "close_menu"}
      phx-keydown={@open? && "close_menu"}
      phx-key="Escape"
    >
      <button
        type="button"
        phx-click="toggle_menu"
        phx-value-menu={@id}
        aria-expanded={@open?}
        aria-haspopup="true"
        class="btn btn-sm gap-1.5 font-normal"
      >
        <.icon name={@icon} class="size-4 opacity-60" />
        <span class="max-w-48 truncate">{@label}</span>
        <.icon name="hero-chevron-down" class="size-3 opacity-40" />
      </button>
      <div
        :if={@open?}
        id={@id <> "-panel"}
        class="dropdown-content z-50 max-h-72 w-72 space-y-1 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :q, :string, required: true
  attr :phrase, :string, required: true
  attr :any, :string, required: true
  attr :none, :string, required: true
  attr :spaces_filter, :string, required: true
  attr :spaces, :list, required: true
  attr :spaces_more?, :boolean, default: false
  attr :creator, :string, required: true
  attr :authors, :list, required: true
  attr :from, :string, required: true
  attr :to, :string, required: true
  attr :updated, :string, required: true
  attr :window_options, :list, required: true

  # The widget-assisted panel. It is one form so any change re-runs the search
  # with everything the reader has set, and every control is a plain input whose
  # value comes back from the URL.
  defp advanced_panel(assigns) do
    ~H"""
    <form
      id="advanced-search"
      phx-change="advanced"
      phx-submit="advanced"
      class="fieldset mt-2 w-full rounded-box bg-base-200 p-3"
    >
      <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-5">
        <.advanced_field name="search[phrase]" label="Exact phrase" value={@phrase} />
        <.advanced_field name="search[any]" label="Any of these words" value={@any} />
        <.advanced_field name="search[none]" label="None of these words" value={@none} />
      </div>

      <div class="mt-2 grid gap-2 sm:grid-cols-2">
        <.advanced_field name="search[from]" label="Modified after" value={@from} type="date" />
        <.advanced_field name="search[to]" label="Modified before" value={@to} type="date" />
      </div>
    </form>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :type, :string, default: "text"
  attr :placeholder, :string, default: nil

  defp advanced_field(assigns) do
    ~H"""
    <label class="block min-w-0">
      <span class="label">{@label}</span>
      <input
        type={@type}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        autocomplete="off"
        class="input input-sm w-full"
      />
    </label>
    """
  end
end
