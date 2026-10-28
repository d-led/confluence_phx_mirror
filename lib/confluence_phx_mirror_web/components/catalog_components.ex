defmodule ConfluencePhxMirrorWeb.CatalogComponents do
  @moduledoc """
  The pieces every catalog shares: the filter box, the result body for one
  catalog kind, and the footer that asks for the next page.

  Sharing them is what makes the catalogs feel like one feature: the same
  debounced filter box narrows the space directory, the people index and a
  space's page table, and the rows are only ever the rows that survived the
  filter. `ConfluencePhxMirror.Catalog` decides what matches; this module only
  decides how a match looks.
  """

  use ConfluencePhxMirrorWeb, :html

  import ConfluencePhxMirrorWeb.MirrorComponents,
    only: [empty_state: 1, initials: 1, label_chips: 1, space_card: 1]

  alias ConfluencePhxMirror.Mirror.Attachment
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Publishing
  alias ConfluencePhxMirrorWeb.Time

  @doc """
  The filter box: one free-form field, debounced, that narrows the catalog as
  the reader types.

  It is a real form, so pressing Enter works too. The field is deliberately
  compact — a catalog is a list you scan, not a search page — and the count
  beside it says how many entries are on screen in the catalog's own words
  ("37 pages", "50+ spaces").
  """
  attr :form, :any, required: true
  attr :q, :string, default: ""
  attr :placeholder, :string, required: true
  attr :count, :integer, default: 0
  attr :singular, :string, required: true
  attr :plural, :string, required: true
  attr :more?, :boolean, default: false
  attr :debounce, :integer, default: 220

  def catalog_filter(assigns) do
    ~H"""
    <.form for={@form} id="catalog-filter" phx-change="filter" phx-submit="filter" class="mt-4">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
        <div class="relative min-w-0 flex-1 sm:max-w-xs">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/70"
          />
          <.input
            field={@form[:q]}
            type="search"
            phx-debounce={@debounce}
            autocomplete="off"
            aria-label={@placeholder}
            placeholder={@placeholder}
            class="h-11 w-full rounded-lg border border-base-300 bg-base-100 pl-9 pr-10 text-base transition focus:border-primary/50 focus:outline-none focus:ring-2 focus:ring-primary/15 sm:h-9 sm:pr-8 sm:text-sm [&::-webkit-search-cancel-button]:appearance-none"
          />
          <button
            :if={@q != ""}
            type="button"
            phx-click="clear"
            class="absolute right-1 top-1/2 grid size-9 -translate-y-1/2 place-items-center rounded text-base-content/70 transition hover:bg-base-200 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 sm:size-7"
            aria-label="Clear filter"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <p
          id="catalog-count"
          role="status"
          aria-live="polite"
          class="text-xs tabular-nums text-base-content/70"
        >
          {@count}{if @more?, do: "+"} {if @count == 1, do: @singular, else: @plural}
        </p>
      </div>
    </.form>
    """
  end

  @doc "The matches themselves, in the shape that suits the catalog."
  attr :kind, :atom, required: true
  attr :items, :list, required: true
  attr :space, :any, default: nil
  attr :sort, :string, default: "title"

  def catalog_body(%{kind: :spaces} = assigns) do
    ~H"""
    <%!-- Rows, not tiles: a three-column grid leaves each card ~300px, which
    is where a description stops being readable. --%>
    <ul
      id="catalog-results"
      class="mt-4 divide-y divide-base-300/60 overflow-hidden rounded-xl border border-base-300/70 bg-base-100"
    >
      <li :for={row <- @items}>
        <.space_card
          space={row.space}
          count={row.pages}
          blog_posts={row.blog_posts}
          updated_at={row.updated_at}
        />
      </li>
    </ul>
    """
  end

  def catalog_body(%{kind: :people} = assigns) do
    ~H"""
    <ul
      id="catalog-results"
      class="mt-4 divide-y divide-base-300/60 overflow-hidden rounded-xl border border-base-300/70 bg-base-100"
    >
      <li :for={author <- @items}>
        <.link
          navigate={URLs.person_path(author.account_id)}
          class="group flex min-h-14 items-center gap-3 px-4 py-3 transition hover:bg-base-200/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 focus-visible:ring-inset"
        >
          <span class="grid size-10 shrink-0 place-items-center rounded-full bg-primary/10 text-sm font-semibold text-primary">
            {initials(author.name)}
          </span>
          <span class="min-w-0">
            <span class="block truncate text-sm font-semibold group-hover:text-primary">
              {author.name}
            </span>
            <span class="block text-[11px] text-base-content/70">
              {author.pages} {if author.pages == 1, do: "item", else: "items"} · updated {Time.ago(
                author.updated_at
              )}
            </span>
          </span>
        </.link>
      </li>
    </ul>
    """
  end

  def catalog_body(%{kind: :labels} = assigns) do
    ~H"""
    <div id="catalog-results" class="mt-4 flex flex-wrap gap-2">
      <a
        :for={label <- @items}
        href={~p"/labels/#{label.name}"}
        class="group inline-flex items-center gap-2 rounded-lg border border-base-300/70 bg-base-100 px-3 py-2 text-sm transition hover:border-primary/40 hover:bg-base-200/40"
      >
        <.icon name="hero-tag" class="size-3.5 text-base-content/70" />
        <span class="font-medium group-hover:text-primary">{label.name}</span>
        <span class="badge badge-ghost badge-xs tabular-nums">{label.pages}</span>
      </a>
    </div>
    """
  end

  def catalog_body(%{kind: :blog} = assigns) do
    ~H"""
    <ul id="catalog-results" class="mt-4 space-y-3">
      <li :for={post <- @items}>
        <article class="group relative rounded-xl border border-base-300/70 bg-base-100 p-4 transition hover:border-primary/40 hover:shadow-sm">
          <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <.link
              navigate={URLs.content_path(@space.key, post)}
              class="text-base font-semibold after:absolute after:inset-0 group-hover:text-primary focus-visible:outline-none focus-visible:after:ring-2 focus-visible:after:ring-primary/50"
            >
              {post.title}
            </.link>
            <span class="text-[11px] uppercase tracking-wide text-base-content/70">
              <.local_time at={post.external_updated_at} format={:date} />
            </span>
          </div>
          <p class="mt-1 line-clamp-2 text-sm leading-relaxed text-base-content/70">
            {String.slice(post.body_text || "", 0, 260)}
          </p>
          <%!-- `relative` keeps the label links clickable above the card-wide overlay. --%>
          <div class="relative z-10 mt-2 flex flex-wrap items-center gap-2">
            <span
              :if={not Publishing.anonymise_contributors?()}
              class="text-[11px] text-base-content/70"
            >
              by {post.author_name}
            </span>
            <.label_chips labels={post.labels} />
          </div>
        </article>
      </li>
    </ul>
    """
  end

  def catalog_body(%{kind: :pages} = assigns) do
    ~H"""
    <%!-- A phone gets the record, not a table with three of five columns
    hidden: title, what it is, who wrote it, when it moved. --%>
    <ul id="catalog-results" class="mt-4 divide-y divide-base-300/60 sm:hidden">
      <li :for={page <- @items}>
        <.link
          navigate={URLs.content_path(@space.key, page)}
          class="flex min-h-14 items-center gap-3 py-2"
        >
          <.icon
            name={if page.type == "blogpost", do: "hero-newspaper", else: "hero-document-text"}
            class="size-4 shrink-0 text-base-content/70"
          />
          <span class="min-w-0 flex-1">
            <span class="block truncate font-medium">{page.title}</span>
            <span class="mt-0.5 block text-xs text-base-content/70">
              {content_kind(page.type)} · {page.status}
              <%= if page.author_name && not Publishing.anonymise_contributors?() do %>
                · {page.author_name}
              <% end %>
            </span>
          </span>
          <span class="shrink-0 text-[11px] text-base-content/70">
            {Time.ago(page.external_updated_at)}
          </span>
        </.link>
      </li>
      <li :if={@items == []} class="py-6 text-center text-xs text-base-content/70">
        No pages match.
      </li>
    </ul>

    <div
      id="catalog-results-table"
      class="mt-4 hidden overflow-x-auto sm:block sm:mx-0 sm:px-0"
    >
      <table class="table table-sm w-full">
        <caption class="sr-only">Pages in {@space.name}</caption>
        <thead>
          <tr class="text-[11px] uppercase tracking-wide text-base-content/70">
            <th scope="col" class="font-medium" aria-sort={aria_sort(@sort, "title")}>
              <button
                type="button"
                id="sort-title"
                phx-click="sort"
                phx-value-sort="title"
                class={[
                  "inline-flex min-h-11 items-center gap-1 sm:min-h-0",
                  sort_tone(@sort == "title")
                ]}
              >
                Title <.icon name={sort_icon(@sort, "title")} class="size-3" />
              </button>
            </th>
            <th scope="col" class="hidden font-medium md:table-cell">Kind</th>
            <th scope="col" class="hidden font-medium sm:table-cell">Status</th>
            <th scope="col" class="hidden font-medium lg:table-cell">Author</th>
            <th scope="col" class="text-right font-medium" aria-sort={aria_sort(@sort, "updated")}>
              <button
                type="button"
                id="sort-updated"
                phx-click="sort"
                phx-value-sort="updated"
                class={[
                  "inline-flex min-h-11 items-center gap-1 sm:min-h-0",
                  sort_tone(@sort == "updated")
                ]}
              >
                Updated <.icon name={sort_icon(@sort, "updated")} class="size-3" />
              </button>
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={page <- @items} class="hover:bg-base-200/50">
            <td class="max-w-[28rem]">
              <.link
                navigate={URLs.content_path(@space.key, page)}
                class="flex min-h-11 items-center gap-2 rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 sm:min-h-8"
              >
                <.icon
                  name={if page.type == "blogpost", do: "hero-newspaper", else: "hero-document-text"}
                  class="size-3.5 shrink-0 text-base-content/70"
                />
                <span class="truncate font-medium">{page.title}</span>
              </.link>
            </td>
            <td class="hidden text-xs text-base-content/70 md:table-cell">
              {content_kind(page.type)}
            </td>
            <td class="hidden sm:table-cell">
              <span class={[
                "badge badge-xs",
                if(page.status == "archived", do: "badge-warning", else: "badge-ghost")
              ]}>
                {page.status}
              </span>
            </td>
            <td class="hidden text-xs text-base-content/70 lg:table-cell">
              {Publishing.byline(page.author_name)}
            </td>
            <td class="whitespace-nowrap text-right text-xs text-base-content/70">
              <.local_time at={page.external_updated_at}>
                {Time.ago(page.external_updated_at)}
              </.local_time>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def catalog_body(%{kind: :attachments} = assigns) do
    ~H"""
    <ul id="catalog-results" class="mt-4 divide-y divide-base-300/60 sm:hidden">
      <li :for={attachment <- @items}>
        <a
          href={
            URLs.attachment_path(
              @space.key,
              attachment.page.confluence_id,
              attachment.confluence_id,
              attachment.filename
            )
          }
          class="flex min-h-14 items-center gap-3 py-2"
        >
          <.icon name="hero-paper-clip" class="size-4 shrink-0 text-base-content/70" />
          <span class="min-w-0 flex-1">
            <span class="block truncate font-medium">{attachment.filename}</span>
            <span class="mt-0.5 block truncate text-xs text-base-content/70">
              {attachment.page.title} · {Attachment.human_size(attachment.byte_size)} · v{attachment.version_number}
            </span>
          </span>
          <span class="shrink-0 text-[11px] text-base-content/70">
            {Time.ago(attachment.external_updated_at)}
          </span>
        </a>
      </li>
      <li :if={@items == []} class="py-6 text-center text-xs text-base-content/70">
        No attachments match.
      </li>
    </ul>

    <div
      id="catalog-results-table"
      class="mt-4 hidden overflow-x-auto sm:block sm:mx-0 sm:px-0"
    >
      <table class="table table-sm w-full">
        <caption class="sr-only">Attachments in {@space.name}</caption>
        <thead>
          <tr class="text-[11px] uppercase tracking-wide text-base-content/70">
            <th scope="col" class="font-medium">File</th>
            <th scope="col" class="hidden font-medium md:table-cell">Page</th>
            <th scope="col" class="hidden text-right font-medium sm:table-cell">Size</th>
            <th scope="col" class="hidden text-right font-medium lg:table-cell">Version</th>
            <th scope="col" class="text-right font-medium">Updated</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={attachment <- @items} class="hover:bg-base-200/50">
            <td class="max-w-[20rem]">
              <a
                href={
                  URLs.attachment_path(
                    @space.key,
                    attachment.page.confluence_id,
                    attachment.confluence_id,
                    attachment.filename
                  )
                }
                class="flex min-h-8 items-center gap-2 rounded font-medium hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
              >
                <.icon name="hero-paper-clip" class="size-3.5 shrink-0 text-base-content/70" />
                <span class="truncate">{attachment.filename}</span>
              </a>
            </td>
            <td class="hidden max-w-[22rem] text-xs md:table-cell">
              <.link
                navigate={URLs.content_path(@space.key, attachment.page)}
                class="truncate text-base-content/70 hover:text-primary"
              >
                {attachment.page.title}
              </.link>
            </td>
            <td class="hidden whitespace-nowrap text-right text-xs tabular-nums text-base-content/70 sm:table-cell">
              {Attachment.human_size(attachment.byte_size)}
            </td>
            <td class="hidden text-right text-xs tabular-nums text-base-content/70 lg:table-cell">
              v{attachment.version_number}
            </td>
            <td class="whitespace-nowrap text-right text-xs text-base-content/70">
              {Time.ago(attachment.external_updated_at)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  The pager at the foot of a catalog.

  Catalogs are large, so they are read a page at a time instead of all at once.
  Offset paging keeps the URL shareable (`?q=…&offset=…`); catalogs are ordered
  by name or title and a sync changes them rarely, so the classic offset caveat
  does not bite here.
  """
  attr :more?, :boolean, default: false
  attr :previous?, :boolean, default: false
  attr :offset, :integer, default: 0
  attr :count, :integer, default: 0

  def catalog_pager(assigns) do
    ~H"""
    <div
      :if={@more? or @previous?}
      class="mt-6 flex flex-wrap items-center justify-center gap-2 border-t border-base-300/60 pt-3"
    >
      <button
        :if={@previous?}
        type="button"
        id="catalog-previous"
        phx-click="previous"
        class="btn btn-sm btn-ghost min-h-11 gap-2 sm:min-h-8"
      >
        <.icon name="hero-arrow-left" class="size-4" /> Previous page
      </button>
      <p class="w-full text-center text-[11px] tabular-nums text-base-content/70 sm:w-auto">
        Showing {@offset + 1}–{@offset + @count}{if @more?, do: " · more results"}
      </p>
      <button
        :if={@more?}
        type="button"
        id="catalog-more"
        phx-click="more"
        class="btn btn-sm btn-ghost min-h-11 gap-2 sm:min-h-8"
      >
        Next page <.icon name="hero-arrow-right" class="size-4" />
      </button>
    </div>
    """
  end

  @doc "Says what a reader can do about an empty catalog."
  attr :empty, :map, required: true

  def catalog_empty(assigns) do
    ~H"""
    <div id="catalog-empty" role="status">
      <.empty_state icon={@empty.icon} title={@empty.title} body={@empty.body} />
    </div>
    """
  end

  defp content_kind("blogpost"), do: "Blog post"
  defp content_kind(_type), do: "Page"

  defp aria_sort("updated", "updated"), do: "descending"
  defp aria_sort(column, column), do: "ascending"
  defp aria_sort(_current, _column), do: "none"

  defp sort_icon("updated", "updated"), do: "hero-chevron-down"
  defp sort_icon(column, column), do: "hero-chevron-up"
  defp sort_icon(_current, _column), do: "hero-arrows-up-down"

  defp sort_tone(true), do: "text-base-content"
  defp sort_tone(false), do: "text-base-content/70 hover:text-base-content"
end
