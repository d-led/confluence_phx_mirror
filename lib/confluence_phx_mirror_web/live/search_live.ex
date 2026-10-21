defmodule ConfluencePhxMirrorWeb.SearchLive do
  @moduledoc """
  Google-like search: one plain-text box with instant debounced results.

  Filters stay out of the way as pills, the way Confluence does it: the space
  and the time window are single-choice pill menus, content types are toggle
  pills, and labels are free-form pills you type and remove. Every control is
  a real button with a 40px tap target, so the row works on touch as well as
  with a mouse. The raw CQL is never exposed; `Mirror.Search.Filters` turns the
  pills into the mirror's own query.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.MirrorComponents

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Search

  # How many results a reader page shows; deployment sized (CM_SEARCH_PAGE_SIZE).
  defp page_size, do: Application.get_env(:confluence_phx_mirror, :search, [])[:page_size] || 30

  @debounce 220
  @type_options [{"page", "Pages"}, {"blogpost", "Blog posts"}]
  @window_options [
    {"", "Any time"},
    {"7d", "Past 7 days"},
    {"30d", "Past 30 days"},
    {"90d", "Past 90 days"},
    {"365d", "Past year"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    spaces = Mirror.list_spaces()
    labels = Mirror.list_labels()

    {:ok,
     assign(socket,
       q: "",
       space: "",
       labels: "",
       types: "",
       updated: "",
       label_query: "",
       results: [],
       terms: [],
       error: nil,
       searched?: false,
       elapsed_ms: nil,
       chips: [],
       spaces: spaces,
       label_catalog: labels,
       recent_pages: Mirror.recent_pages(6),
       type_options: @type_options,
       window_options: @window_options,
       form: to_form(empty_params(), as: :search),
       debounce: @debounce
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = take_filters(params)
    started = System.monotonic_time(:microsecond)

    {results, terms, error} =
      case Search.structured(filters, limit: page_size()) do
        {:ok, results, terms} -> {results, terms, nil}
        {:error, message} -> {[], [], message}
      end

    elapsed = Float.round((System.monotonic_time(:microsecond) - started) / 1000, 1)

    {:noreply,
     assign(socket,
       q: filters["q"],
       space: filters["space"],
       labels: filters["labels"],
       types: filters["types"],
       updated: filters["updated"],
       results: results,
       terms: terms,
       error: error,
       searched?: Enum.any?(filters, fn {_key, value} -> value != "" end),
       elapsed_ms: elapsed,
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
    %{"q" => "", "space" => "", "labels" => "", "types" => "", "updated" => ""}
  end

  defp current_filters(socket) do
    %{
      "q" => socket.assigns.q,
      "space" => socket.assigns.space,
      "labels" => socket.assigns.labels,
      "types" => socket.assigns.types,
      "updated" => socket.assigns.updated
    }
  end

  defp take_filters(params) do
    %{
      "q" => clean(params["q"]),
      "space" => clean(params["space"]),
      "labels" => (params["labels"] || params["label"]) |> label_values() |> Enum.join(","),
      "types" => (params["types"] || params["type"]) |> label_values() |> Enum.join(","),
      "updated" => clean(params["updated"])
    }
  end

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
      {"space", filters["space"]},
      {"updated", filters["updated"]}
    ]

    types = Enum.map(label_values(filters["types"]), &{"types", &1})

    (base ++ types)
    |> Enum.reject(fn {_key, value} -> value == "" end)
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
      page_title={if @searched?, do: "Search · #{@q}", else: "Search"}
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
          <div class="flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-4 py-2 shadow-sm transition focus-within:border-primary/50 focus-within:shadow-md">
            <.icon name="hero-magnifying-glass" class="size-5 shrink-0 text-base-content/40" />
            <.input
              field={@form[:q]}
              type="search"
              aria-label="Search"
              placeholder="Search pages, decisions, people…"
              autocomplete="off"
              autofocus
              phx-debounce={@debounce}
              class="w-full border-0 bg-transparent p-1 text-base focus:outline-none focus:ring-0"
            />
            <button
              :if={@searched?}
              type="button"
              phx-click="clear"
              class="btn btn-ghost btn-sm rounded-full"
              aria-label="Clear search"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
            <button type="submit" class="btn btn-primary btn-sm rounded-full px-4">Search</button>
          </div>
        </.form>

        <.filter_bar
          space={@space}
          spaces={@spaces}
          types={@types}
          type_options={@type_options}
          updated={@updated}
          window_options={@window_options}
          labels={@labels}
          label_query={@label_query}
          label_catalog={@label_catalog}
        />

        <div class="mt-3 flex flex-wrap items-center gap-1.5">
          <span :if={@chips == [] and @labels == ""} class="text-[11px] text-base-content/40">
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
            class="ml-1 text-[11px] text-base-content/45 hover:text-primary"
          >
            Clear all
          </a>
        </div>

        <div :if={@error} class="mt-4 alert alert-error alert-soft text-sm">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          <span>{@error}</span>
        </div>

        <div :if={@searched? and is_nil(@error)} class="mt-6 flex items-baseline justify-between">
          <p class="text-xs text-base-content/50">
            {length(@results)} result(s)
          </p>
          <p :if={@elapsed_ms} class="text-[10px] tabular-nums text-base-content/35">
            {@elapsed_ms} ms
          </p>
        </div>

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
            <h2 class="mb-3 text-[11px] font-semibold uppercase tracking-wider text-base-content/40">
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
                <.icon name="hero-document-text" class="size-4 shrink-0 text-base-content/35" />
                <span class="min-w-0 flex-1 truncate text-sm group-hover:text-primary">{page.title}</span>
                <span class="shrink-0 text-[10px] text-base-content/35">{page.space.key}</span>
              </.link>
            </div>
          </section>

          <section :if={@label_catalog != []} class="mt-8">
            <h2 class="mb-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/40">
              Browse by label
            </h2>
            <div class="flex flex-wrap gap-1.5">
              <a
                :for={{label, count} <- Enum.take(@label_catalog, 12)}
                href={~p"/labels/#{label}"}
                class="badge badge-outline badge-sm"
              >
                {label} <span class="ml-0.5 text-base-content/40">{count}</span>
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
  attr :types, :string, required: true
  attr :type_options, :list, required: true
  attr :updated, :string, required: true
  attr :window_options, :list, required: true
  attr :labels, :string, required: true
  attr :label_query, :string, required: true
  attr :label_catalog, :list, required: true

  defp filter_bar(assigns) do
    ~H"""
    <div class="mt-3 flex flex-wrap items-center gap-2" id="search-filters">
      <details class="dropdown">
        <summary
          id="space-filter"
          class="btn btn-sm h-10 min-h-10 gap-1.5 rounded-full border-base-300 bg-base-100 px-3 font-normal"
        >
          <.icon name="hero-rectangle-stack" class="size-4 text-base-content/45" />
          <span class="max-w-40 truncate">{space_label(@space, @spaces)}</span>
          <.icon name="hero-chevron-down" class="size-3 opacity-45" />
        </summary>
        <ul class="menu dropdown-content z-50 mt-1 max-h-80 w-64 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 shadow-xl">
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
            "btn btn-sm h-10 min-h-10 rounded-full border-base-300 px-3.5 font-normal",
            value in label_values(@types) && "border-primary bg-primary/10 text-primary"
          ]}
        >
          {label}
        </button>
      </div>

      <details class="dropdown">
        <summary
          id="updated-filter"
          class="btn btn-sm h-10 min-h-10 gap-1.5 rounded-full border-base-300 bg-base-100 px-3 font-normal"
        >
          <.icon name="hero-clock" class="size-4 text-base-content/45" />
          {updated_label(@updated)}
          <.icon name="hero-chevron-down" class="size-3 opacity-45" />
        </summary>
        <ul class="menu dropdown-content z-50 mt-1 w-52 rounded-box border border-base-300 bg-base-100 p-1 shadow-xl">
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

      <div class="flex flex-wrap items-center gap-1.5" id="label-pills">
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
            class="h-10 w-28 rounded-full border border-dashed border-base-300 bg-base-100 px-3 text-xs placeholder:text-base-content/40 focus:border-primary/50 focus:outline-none sm:w-36 [&::-webkit-calendar-picker-indicator]:hidden"
          />
          <datalist id="label-suggestions">
            <option :for={{name, _count} <- @label_catalog} value={name} />
          </datalist>
        </form>
      </div>
    </div>
    """
  end
end
