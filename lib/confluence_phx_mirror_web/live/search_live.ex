defmodule ConfluencePhxMirrorWeb.SearchLive do
  @moduledoc """
  Google-like search: one plain-text box with instant debounced results and a
  row of structured filters (space, label, type, freshness).

  The filters are compiled to the CQL subset internally by
  `Mirror.Search.Filters`; there is no raw CQL input in the reader UI.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.MirrorComponents

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Search

  # How many results a reader page shows; deployment sized (CM_SEARCH_PAGE_SIZE).
  defp page_size, do: Application.get_env(:confluence_phx_mirror, :search, [])[:page_size] || 30

  @debounce 220

  @impl true
  def mount(_params, _session, socket) do
    spaces = Mirror.list_spaces()
    labels = Mirror.list_labels()

    {:ok,
     assign(socket,
       q: "",
       space: "",
       label: "",
       type: "",
       updated: "",
       results: [],
       terms: [],
       error: nil,
       searched?: false,
       elapsed_ms: nil,
       chips: [],
       spaces: spaces,
       labels: labels,
       recent_pages: Mirror.recent_pages(6),
       space_options: [{"All spaces", ""} | Enum.map(spaces, &{&1.name, &1.key})],
       label_options: [
         {"All labels", ""} | Enum.map(labels, fn {name, _count} -> {name, name} end)
       ],
       type_options: [{"Any type", ""}, {"Pages", "page"}, {"Blog posts", "blogpost"}],
       updated_options: [
         {"Any time", ""},
         {"Past 7 days", "7d"},
         {"Past 30 days", "30d"},
         {"Past 90 days", "90d"},
         {"Past year", "365d"}
       ],
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
       label: filters["label"],
       type: filters["type"],
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
    filters = take_filters(params)
    {:noreply, push_patch(socket, to: search_path(filters), replace: true)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/search")}
  end

  defp empty_params, do: %{"q" => "", "space" => "", "label" => "", "type" => "", "updated" => ""}

  defp take_filters(params) do
    Map.new(empty_params(), fn {key, _default} ->
      {key, params |> Map.get(key, "") |> to_string() |> String.trim()}
    end)
  end

  defp search_path(filters) do
    query =
      filters
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> URI.encode_query()

    if query == "", do: ~p"/search", else: "/search?" <> query
  end

  defp chips(filters) do
    filters
    |> Enum.reject(fn {_key, value} -> value == "" end)
    |> Enum.map(fn {key, value} ->
      %{
        key: key,
        label: chip_label(key, value),
        path: search_path(Map.put(filters, key, ""))
      }
    end)
  end

  defp chip_label("q", value), do: ~s(“#{value}”)
  defp chip_label("space", value), do: "Space: #{value}"
  defp chip_label("label", value), do: "Label: #{value}"
  defp chip_label("type", "page"), do: "Type: pages"
  defp chip_label("type", "blogpost"), do: "Type: blog posts"
  defp chip_label("type", value), do: "Type: #{value}"
  defp chip_label("updated", "7d"), do: "Past 7 days"
  defp chip_label("updated", "30d"), do: "Past 30 days"
  defp chip_label("updated", "90d"), do: "Past 90 days"
  defp chip_label("updated", "365d"), do: "Past year"
  defp chip_label("updated", value), do: "Updated: #{value}"
  defp chip_label(key, value), do: "#{key}: #{value}"

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
              class="btn btn-ghost btn-xs rounded-full"
              aria-label="Clear search"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
            <button type="submit" class="btn btn-primary btn-sm rounded-full px-4">Search</button>
          </div>

          <div class="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
            <.input
              field={@form[:space]}
              type="select"
              options={@space_options}
              class="select-sm rounded-full"
            />
            <.input
              field={@form[:label]}
              type="select"
              options={@label_options}
              class="select-sm rounded-full"
            />
            <.input
              field={@form[:type]}
              type="select"
              options={@type_options}
              class="select-sm rounded-full"
            />
            <.input
              field={@form[:updated]}
              type="select"
              options={@updated_options}
              class="select-sm rounded-full"
            />
          </div>
        </.form>

        <div class="mt-3 flex flex-wrap items-center gap-1.5">
          <span :if={@chips == []} class="text-[11px] text-base-content/40">
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
            :if={length(@chips) > 1}
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

          <section :if={@labels != []} class="mt-8">
            <h2 class="mb-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/40">
              Browse by label
            </h2>
            <div class="flex flex-wrap gap-1.5">
              <a
                :for={{label, count} <- Enum.take(@labels, 12)}
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
end
