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
  @type_options [{"page", "Pages"}, {"blogpost", "Blog posts"}]
  @sort_options [{"", "Best match"}, {"newest", "Newest first"}, {"oldest", "Oldest first"}]
  @window_options [
    {"", "Any time"},
    {"7d", "Past 7 days"},
    {"30d", "Past 30 days"},
    {"90d", "Past 90 days"},
    {"365d", "Past year"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    # The space menus are drawn twice on this screen (the pill bar and the
    # advanced panel), so a mirror with a thousand spaces would send a thousand
    # entries twice with every search. They take a window; a space's own catalog
    # filters inside that space.
    spaces = Mirror.list_spaces(limit: @space_window)
    labels = Catalog.label_counts(socket.assigns.current_scope)

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
       results: [],
       terms: [],
       error: nil,
       searched?: false,
       chips: [],
       page_title: "Search",
       spaces: spaces,
       spaces_more?: Mirror.stats().spaces > length(spaces),
       authors: Mirror.authors(),
       label_catalog: labels,
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
        "q" => clean(params["q"]),
        "phrase" => clean(params["phrase"]),
        "any" => clean(params["any"]),
        "none" => clean(params["none"]),
        "spaces" => params |> Map.get("spaces", []) |> List.wrap() |> Enum.join(","),
        "creator" => clean(params["creator"]),
        "from" => clean(params["from"]),
        "to" => clean(params["to"]),
        "sort" => clean(params["sort"])
      })

    {:noreply, patch(socket, filters)}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :advanced?, not (socket.assigns.advanced? || false))}
  end

  def handle_event("set_sort", %{"sort" => value}, socket) do
    {:noreply, patch(socket, Map.put(current_filters(socket), "sort", clean(value)))}
  end

  def handle_event("set_space", %{"value" => value}, socket) do
    space = if value == socket.assigns.space, do: "", else: value
    {:noreply, patch(socket, Map.put(current_filters(socket), "space", space))}
  end

  def handle_event("toggle_type", %{"value" => value}, socket) do
    types = toggle(label_values(socket.assigns.types), value)

    {:noreply, patch(socket, Map.put(current_filters(socket), "types", Enum.join(types, ",")))}
  end

  def handle_event("set_updated", %{"value" => value}, socket) do
    updated = if value == socket.assigns.updated, do: "", else: value

    {:noreply, patch(socket, Map.put(current_filters(socket), "updated", updated))}
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

    (base ++ types)
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

  defp remove(filters, key, _value), do: Map.put(filters, key, "")

  defp chip_label("q", value), do: ~s(“#{value}”)
  defp chip_label("phrase", value), do: ~s(Phrase: “#{value}”)
  defp chip_label("any", value), do: "Any of: #{value}"
  defp chip_label("none", value), do: "Without: #{value}"
  defp chip_label("spaces", value), do: "Spaces: #{String.replace(value, ",", ", ")}"
  defp chip_label("creator", value), do: "By: #{value}"
  defp chip_label("from", value), do: "Modified after #{value}"
  defp chip_label("to", value), do: "Modified before #{value}"
  defp chip_label("sort", "newest"), do: "Sort: newest first"
  defp chip_label("sort", "oldest"), do: "Sort: oldest first"
  defp chip_label("space", value), do: "Space: #{value}"
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

  defp spaces_label(filter, spaces) do
    case space_values(filter) do
      [] -> "All spaces"
      [one] -> space_label(one, spaces)
      several -> "#{length(several)} spaces"
    end
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
        <.form
          for={@form}
          id="search-form"
          phx-change="search"
          phx-submit="search"
          class="mt-2 sm:mt-6"
        >
          <div class="flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-4 py-2 shadow-sm transition focus-within:ring-2 focus-within:ring-primary/50">
            <.icon name="hero-magnifying-glass" class="size-5 shrink-0 text-base-content/70" />
            <.input
              field={@form[:q]}
              type="search"
              aria-label="Search"
              placeholder="Search pages, decisions, people…"
              autocomplete="off"
              autofocus
              phx-debounce={@debounce}
              class="min-h-11 min-w-0 flex-1 border-0 bg-transparent p-1 text-base focus:outline-none sm:min-h-0 [&::-webkit-search-cancel-button]:appearance-none [&::-webkit-search-decoration]:appearance-none"
            />
            <%!-- One clear affordance, ours: the browser draws its own cancel
            button for type="search", which sat next to this one. --%>
            <button
              :if={@q != ""}
              type="button"
              phx-click="clear"
              class="grid size-11 shrink-0 place-items-center rounded-full text-base-content/70 transition hover:bg-base-200 hover:text-base-content sm:size-8"
              aria-label="Clear search"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm min-h-11 shrink-0 rounded-full px-4 sm:min-h-8"
            >
              Search
            </button>
          </div>
        </.form>

        <.filter_bar
          space={@space}
          spaces={@spaces}
          spaces_more?={@spaces_more?}
          types={@types}
          type_options={@type_options}
          updated={@updated}
          window_options={@window_options}
          labels={@labels}
          label_query={@label_query}
          label_catalog={@label_catalog}
        />

        <div class="mt-2 flex items-center justify-between gap-2">
          <button
            id="advanced-toggle"
            type="button"
            phx-click="toggle_advanced"
            aria-expanded={@advanced?}
            class={[
              "inline-flex h-9 items-center gap-1.5 rounded-full px-3 text-xs font-medium transition",
              @advanced? && "bg-primary/10 text-primary",
              !@advanced? && "text-base-content/60 hover:bg-base-200/60 hover:text-base-content"
            ]}
          >
            <.icon name="hero-adjustments-horizontal" class="size-4" />
            {if @advanced?, do: "Hide advanced search", else: "Advanced search"}
          </button>

          <label class="flex items-center gap-1.5 text-[11px] text-base-content/70">
            <span>Sort</span>
            <select
              id="sort-filter"
              class="select select-xs rounded-full border-base-300 bg-base-100"
              phx-change="set_sort"
              name="sort"
            >
              <option :for={{value, label} <- @sort_options} value={value} selected={value == @sort}>
                {label}
              </option>
            </select>
          </label>
        </div>

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

        <div class="mt-3 flex flex-wrap items-center gap-1.5">
          <span :if={@chips == [] and @labels == ""} class="text-[11px] text-base-content/70">
            <span class="font-medium">Tip:</span> filters combine with your words.
          </span>
          <a
            :for={chip <- @chips}
            href={chip.path}
            class="inline-flex items-center gap-1 rounded-full border border-primary/30 bg-primary/10 px-2.5 py-0.5 text-[11px] font-medium text-primary transition hover:bg-primary/20"
          >
            {chip.label}
            <.icon name="hero-x-mark" class="size-3" />
          </a>
          <a
            :if={length(@chips) + length(label_values(@labels)) > 1}
            href={~p"/search"}
            class="ml-1 text-[11px] text-base-content/70 hover:text-primary"
          >
            Clear all
          </a>
        </div>

        <div :if={@error} class="mt-4 alert alert-error alert-soft text-sm">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          <span>{@error}</span>
        </div>

        <p :if={@searched? and is_nil(@error)} class="mt-6 text-xs text-base-content/70">
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

          <section :if={@label_catalog != []} class="mt-8">
            <h2 class="mb-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/70">
              Browse by label
            </h2>
            <div class="flex flex-wrap gap-1.5">
              <a
                :for={%{name: label, pages: count} <- Enum.take(@label_catalog, 12)}
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
  attr :types, :string, required: true
  attr :type_options, :list, required: true
  attr :updated, :string, required: true
  attr :window_options, :list, required: true
  attr :labels, :string, required: true
  attr :label_query, :string, required: true
  attr :label_catalog, :list, required: true

  defp filter_bar(assigns) do
    ~H"""
    <div class="mt-3 flex min-w-0 flex-wrap items-center gap-2" id="search-filters">
      <details class="dropdown">
        <summary
          id="space-filter"
          class="btn btn-sm h-11 min-h-11 gap-1.5 rounded-full border-base-300 bg-base-100 px-3 font-normal"
        >
          <.icon name="hero-rectangle-stack" class="size-4 text-base-content/70" />
          <span class="max-w-40 truncate">{space_label(@space, @spaces)}</span>
          <.icon name="hero-chevron-down" class="size-3 opacity-45" />
        </summary>
        <ul class="menu dropdown-content z-50 mt-1 max-h-80 w-64 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 shadow-lg">
          <li>
            <button
              type="button"
              phx-click="set_space"
              phx-value-value=""
              class={[@space == "" && "active"]}
            >
              All spaces
            </button>
          </li>
          <li :for={space <- @spaces}>
            <button
              type="button"
              phx-click="set_space"
              phx-value-value={space.key}
              class={[@space == space.key && "active"]}
            >
              <span class="min-w-0 flex-1 truncate">{space.name}</span>
              <span class="badge badge-ghost badge-xs">{space.key}</span>
            </button>
          </li>
          <li :if={@spaces_more?}>
            <a href={~p"/spaces"} class="text-xs text-primary">More spaces →</a>
          </li>
        </ul>
      </details>

      <div class="flex flex-wrap items-center gap-2">
        <button
          :for={{value, label} <- @type_options}
          type="button"
          phx-click="toggle_type"
          phx-value-value={value}
          aria-pressed={value in label_values(@types)}
          class={[
            "btn btn-sm h-11 min-h-11 rounded-full border-base-300 px-3.5 font-normal",
            value in label_values(@types) && "border-primary bg-primary/10 text-primary"
          ]}
        >
          {label}
        </button>
      </div>

      <details class="dropdown">
        <summary
          id="updated-filter"
          class="btn btn-sm h-11 min-h-11 gap-1.5 rounded-full border-base-300 bg-base-100 px-3 font-normal"
        >
          <.icon name="hero-clock" class="size-4 text-base-content/70" />
          {updated_label(@updated)}
          <.icon name="hero-chevron-down" class="size-3 opacity-45" />
        </summary>
        <ul class="menu dropdown-content z-50 mt-1 w-52 rounded-box border border-base-300 bg-base-100 p-1 shadow-lg">
          <li :for={{value, label} <- @window_options}>
            <button
              type="button"
              phx-click="set_updated"
              phx-value-value={value}
              class={[@updated == value && "active"]}
            >
              {label}
            </button>
          </li>
        </ul>
      </details>

      <div class="flex min-w-0 flex-wrap items-center gap-1.5" id="label-pills">
        <span
          :for={label <- label_values(@labels)}
          class="inline-flex h-10 items-center gap-1 rounded-full border border-primary/30 bg-primary/10 pl-3 pr-1 text-xs font-medium text-primary"
        >
          {label}
          <button
            type="button"
            phx-click="toggle_label"
            phx-value-label={label}
            class="grid size-8 place-items-center rounded-full transition hover:bg-primary/20"
            aria-label={"Remove label #{label}"}
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </span>

        <form id="label-form" phx-change="label_query" phx-submit="add_label" class="flex">
          <input
            type="text"
            name="label"
            value={@label_query}
            list="label-suggestions"
            placeholder="+ label"
            autocomplete="off"
            phx-debounce="150"
            class="h-11 w-28 rounded-full border border-dashed border-base-300 bg-base-100 px-3 text-xs placeholder:text-base-content/70 focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/50 sm:h-10 sm:w-36 [&::-webkit-calendar-picker-indicator]:hidden"
          />
          <datalist id="label-suggestions">
            <option :for={%{name: name} <- @label_catalog} value={name} />
          </datalist>
        </form>
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
      class="mt-2 rounded-xl border border-base-300/70 bg-base-200/30 p-3"
    >
      <div class="grid gap-2 sm:grid-cols-2">
        <.advanced_field
          name="search[q]"
          label="All of these words"
          value={@q}
          placeholder="rate limit"
        />
        <.advanced_field
          name="search[phrase]"
          label="This exact phrase"
          value={@phrase}
          placeholder="token bucket"
        />
        <.advanced_field
          name="search[any]"
          label="Any of these words"
          value={@any}
          placeholder="runbook incident"
        />
        <.advanced_field
          name="search[none]"
          label="None of these words"
          value={@none}
          placeholder="draft obsolete"
        />
      </div>

      <div class="mt-2 grid gap-2 sm:grid-cols-3">
        <details class="dropdown">
          <summary class="btn btn-sm h-9 min-h-9 w-full justify-between gap-1 rounded-lg border-base-300 bg-base-100 px-3 font-normal">
            <span class="min-w-0 truncate">{spaces_label(@spaces_filter, @spaces)}</span>
            <.icon name="hero-chevron-down" class="size-3 shrink-0 opacity-45" />
          </summary>
          <ul class="menu dropdown-content z-50 mt-1 max-h-64 w-64 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 shadow-lg">
            <li :for={space <- @spaces}>
              <label class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name="search[spaces][]"
                  value={space.key}
                  checked={space.key in space_values(@spaces_filter)}
                  class="checkbox checkbox-xs checkbox-primary"
                />
                <span class="min-w-0 flex-1 truncate">{space.name}</span>
                <span class="text-[10px] text-base-content/70">{space.key}</span>
              </label>
            </li>
            <li :if={@spaces == []} class="menu-disabled"><span>Nothing mirrored yet</span></li>
          </ul>
        </details>

        <select
          id="advanced-creator"
          name="search[creator]"
          aria-label="Contributor"
          class="select select-sm h-9 min-h-9 w-full rounded-lg border-base-300 bg-base-100"
        >
          <option value="">Anyone</option>
          <option :for={author <- @authors} value={author.name} selected={author.name == @creator}>
            {author.name} ({author.pages})
          </option>
        </select>

        <select
          id="advanced-updated"
          name="updated"
          aria-label="Last modified"
          phx-change="set_updated"
          class="select select-sm h-9 min-h-9 w-full rounded-lg border-base-300 bg-base-100"
        >
          <option :for={{value, label} <- @window_options} value={value} selected={value == @updated}>
            {label}
          </option>
        </select>
      </div>

      <div class="mt-2 flex items-center gap-1.5">
        <input
          type="date"
          name="search[from]"
          value={@from}
          aria-label="Modified after"
          class="input input-sm h-9 min-h-9 w-full min-w-0 rounded-lg border-base-300 bg-base-100"
        />
        <span class="shrink-0 text-[11px] text-base-content/70">to</span>
        <input
          type="date"
          name="search[to]"
          value={@to}
          aria-label="Modified before"
          class="input input-sm h-9 min-h-9 w-full min-w-0 rounded-lg border-base-300 bg-base-100"
        />
      </div>

      <div class="mt-2 flex items-center justify-between gap-2 text-[11px] text-base-content/70">
        <p :if={@spaces_more?}>
          More spaces exist. <a href={~p"/spaces"} class="text-primary">Browse them all</a>.
        </p>
        <p :if={not @spaces_more?} class="truncate">
          Any widens, None excludes; several spaces search together.
        </p>
        <a href={~p"/search"} class="link link-hover shrink-0 text-primary">Reset</a>
      </div>
    </form>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :placeholder, :string, default: nil

  defp advanced_field(assigns) do
    ~H"""
    <label class="block min-w-0">
      <span class="mb-0.5 block text-[11px] font-medium text-base-content/70">{@label}</span>
      <input
        type="text"
        name={@name}
        value={@value}
        placeholder={@placeholder}
        autocomplete="off"
        phx-debounce="400"
        class="input input-sm h-9 min-h-9 w-full rounded-lg border-base-300 bg-base-100"
      />
    </label>
    """
  end
end
