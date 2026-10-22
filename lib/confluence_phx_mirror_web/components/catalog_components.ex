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
            class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
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
            class="absolute right-1 top-1/2 grid size-9 -translate-y-1/2 place-items-center rounded text-base-content/40 transition hover:bg-base-200 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 sm:size-7"
            aria-label="Clear filter"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <p
          id="catalog-count"
          role="status"
          aria-live="polite"
          class="text-xs tabular-nums text-base-content/50"
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

  def catalog_body(%{kind: :spaces} = assigns) do
    ~H"""
    <div id="catalog-results" class="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      <.space_card
        :for={row <- @items}
        space={row.space}
        count={row.pages}
        blog_posts={row.blog_posts}
        updated_at={row.updated_at}
      />
    </div>
    """
  end

  def catalog_body(%{kind: :people} = assigns) do
    ~H"""
    <ul id="catalog-results" class="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      <li :for={author <- @items}>
        <.link
          navigate={URLs.person_path(author.account_id)}
          class="group flex items-center gap-3 rounded-xl border border-base-300/70 bg-base-100 p-4 transition hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 motion-reduce:hover:translate-y-0"
        >
          <span class="grid size-10 shrink-0 place-items-center rounded-full bg-primary/10 text-sm font-semibold text-primary">
            {initials(author.name)}
          </span>
          <span class="min-w-0">
            <span class="block truncate text-sm font-semibold group-hover:text-primary">
              {author.name}
            </span>
            <span class="block text-[11px] text-base-content/45">
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
    <div id="catalog-results" class="mt-6 flex flex-wrap gap-2">
      <a
        :for={label <- @items}
        href={~p"/labels/#{label.name}"}
        class="group inline-flex items-center gap-2 rounded-lg border border-base-300/70 bg-base-100 px-3 py-2 text-sm transition hover:border-primary/40 hover:bg-base-200/40"
      >
        <.icon name="hero-tag" class="size-3.5 text-base-content/40" />
        <span class="font-medium group-hover:text-primary">{label.name}</span>
        <span class="badge badge-ghost badge-xs tabular-nums">{label.pages}</span>
      </a>
    </div>
    """
  end

  def catalog_body(%{kind: :blog} = assigns) do
    ~H"""
    <ul id="catalog-results" class="mt-6 space-y-3">
      <li :for={post <- @items}>
        <article class="group relative rounded-xl border border-base-300/70 bg-base-100 p-4 transition hover:border-primary/40 hover:shadow-sm">
          <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <.link
              navigate={URLs.content_path(@space.key, post)}
              class="text-base font-semibold after:absolute after:inset-0 group-hover:text-primary focus-visible:outline-none focus-visible:after:ring-2 focus-visible:after:ring-primary/50"
            >
              {post.title}
            </.link>
            <span class="text-[11px] uppercase tracking-wide text-base-content/40">
              {Time.date(post.external_updated_at)}
            </span>
          </div>
          <p class="mt-1 line-clamp-2 text-sm leading-relaxed text-base-content/60">
            {String.slice(post.body_text || "", 0, 260)}
          </p>
          <%!-- `relative` keeps the label links clickable above the card-wide overlay. --%>
          <div class="relative z-10 mt-2 flex flex-wrap items-center gap-2">
            <span class="text-[11px] text-base-content/45">by {post.author_name}</span>
            <.label_chips labels={post.labels} />
          </div>
        </article>
      </li>
    </ul>
    """
  end

  def catalog_body(%{kind: :pages} = assigns) do
    ~H"""
    <div id="catalog-results" class="-mx-4 mt-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
      <table class="table table-sm w-full">
        <caption class="sr-only">Pages in {@space.name}</caption>
        <thead>
          <tr class="text-[11px] uppercase tracking-wide text-base-content/45">
            <th scope="col" class="font-medium">Title</th>
            <th scope="col" class="hidden font-medium md:table-cell">Kind</th>
            <th scope="col" class="hidden font-medium sm:table-cell">Status</th>
            <th scope="col" class="hidden font-medium lg:table-cell">Author</th>
            <th scope="col" class="text-right font-medium">Updated</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={page <- @items} class="hover:bg-base-200/50">
            <td class="max-w-[28rem]">
              <.link
                navigate={URLs.content_path(@space.key, page)}
                class="flex min-h-8 items-center gap-2 rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
              >
                <.icon
                  name={if page.type == "blogpost", do: "hero-newspaper", else: "hero-document-text"}
                  class="size-3.5 shrink-0 text-base-content/40"
                />
                <span class="truncate font-medium">{page.title}</span>
              </.link>
            </td>
            <td class="hidden text-xs text-base-content/60 md:table-cell">
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
            <td class="hidden text-xs text-base-content/60 lg:table-cell">{page.author_name}</td>
            <td
              class="whitespace-nowrap text-right text-xs text-base-content/55"
              title={Time.datetime(page.external_updated_at)}
            >
              {Time.ago(page.external_updated_at)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def catalog_body(%{kind: :attachments} = assigns) do
    ~H"""
    <div id="catalog-results" class="-mx-4 mt-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
      <table class="table table-sm w-full">
        <caption class="sr-only">Attachments in {@space.name}</caption>
        <thead>
          <tr class="text-[11px] uppercase tracking-wide text-base-content/45">
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
                <.icon name="hero-paper-clip" class="size-3.5 shrink-0 text-base-content/40" />
                <span class="truncate">{attachment.filename}</span>
              </a>
            </td>
            <td class="hidden max-w-[22rem] text-xs md:table-cell">
              <.link
                navigate={URLs.content_path(@space.key, attachment.page)}
                class="truncate text-base-content/60 hover:text-primary"
              >
                {attachment.page.title}
              </.link>
            </td>
            <td class="hidden whitespace-nowrap text-right text-xs tabular-nums text-base-content/55 sm:table-cell">
              {Attachment.human_size(attachment.byte_size)}
            </td>
            <td class="hidden text-right text-xs tabular-nums text-base-content/55 lg:table-cell">
              v{attachment.version_number}
            </td>
            <td class="whitespace-nowrap text-right text-xs text-base-content/55">
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

  def catalog_pager(assigns) do
    ~H"""
    <div
      :if={@more? or @previous?}
      class="mt-8 flex items-center justify-center gap-2 border-t border-base-300/60 pt-4"
    >
      <button
        :if={@previous?}
        type="button"
        id="catalog-previous"
        phx-click="previous"
        class="btn btn-sm btn-ghost gap-2"
      >
        <.icon name="hero-arrow-left" class="size-4" /> Previous page
      </button>
      <button
        :if={@more?}
        type="button"
        id="catalog-more"
        phx-click="more"
        class="btn btn-sm btn-ghost gap-2"
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
end
