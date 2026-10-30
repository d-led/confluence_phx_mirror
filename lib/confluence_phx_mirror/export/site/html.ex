defmodule ConfluencePhxMirror.Export.Site.HTML do
  @moduledoc """
  The pages of an exported site: the same shell, type and colours as the mirror
  a reader knows, written as plain HTML.

  Nothing here needs a script: the heading permalinks are already in the body
  (see `ConfluencePhxMirror.Export.Site.Content`), the theme is one stylesheet,
  and every link is a file inside the archive. What the reader screens get from
  LiveView — search, presence, the space switcher — has no business in a folder
  of files, so it is absent rather than broken.
  """

  use Phoenix.Component

  alias ConfluencePhxMirror.Export.Site
  alias ConfluencePhxMirror.Publishing

  @doc """
  The archive's front page.

  `:spaces` are `%{name, key, href, icon, description, page_count}` maps.
  """
  attr :title, :string, required: true
  attr :spaces, :list, required: true
  attr :page_count, :integer, required: true
  attr :generated, :string, required: true
  attr :mirror_name, :string, required: true
  attr :mirror_url, :string, default: nil
  attr :html_attributes, :map, default: %{}

  def site(assigns) do
    ~H"""
    <.shell
      title={@title}
      prefix=""
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      html_attributes={@html_attributes}
      note={"#{plural(@page_count, "page")} in #{plural(length(@spaces), "space")}, copied #{@generated}."}
    >
      <:nav>
        <p class="mb-3 text-xs font-semibold uppercase tracking-wider text-base-content/70">
          Spaces
        </p>
        <ul class="menu menu-sm w-full gap-1 p-0">
          <li :for={space <- @spaces}>
            <a href={space.href} class="truncate">
              {space.name}
              <span class="badge badge-ghost badge-xs">{space.key}</span>
            </a>
          </li>
        </ul>
        <.labels_link prefix="" />
      </:nav>

      <h1 class="text-2xl font-semibold tracking-tight">{@title}</h1>
      <p class="mt-1 max-w-2xl text-sm text-base-content/70">
        A static copy of the mirror. Every page here works without a server: open
        <code>index.html</code>
        from the folder and the links stay inside it. Links to content the mirror did not
        carry go back to the original site.
      </p>

      <div class="mt-5 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
        <a
          :for={space <- @spaces}
          href={space.href}
          class="group flex flex-col gap-1 rounded-xl border border-base-300/70 bg-base-100 p-4 transition hover:border-primary/40 hover:bg-base-200/40"
        >
          <span class="flex min-w-0 items-center gap-2">
            <img
              :if={space.icon}
              src={space.icon}
              alt=""
              loading="lazy"
              class="size-6 shrink-0 rounded"
            />
            <span
              :if={is_nil(space.icon)}
              class="grid size-6 shrink-0 place-items-center rounded bg-primary text-[11px] font-bold text-primary-content"
            >
              {initial(space.name)}
            </span>
            <span class="truncate text-sm font-semibold group-hover:text-primary">
              {space.name}
            </span>
            <span class="badge badge-outline badge-xs ml-auto shrink-0">{space.key}</span>
          </span>
          <span :if={space.description != ""} class="line-clamp-2 text-xs text-base-content/70">
            {space.description}
          </span>
          <span class="mt-1 text-[11px] uppercase tracking-wide text-base-content/70">
            {plural(space.page_count, "page")}
          </span>
        </a>
      </div>
    </.shell>
    """
  end

  @doc """
  A space's front page: its description and its whole page tree.

  `:tree` carries `%{title, href, confluence_id, children}` nodes;
  `:home` is `%{title, href}` for the space's home page, or `nil`.
  """
  attr :title, :string, required: true
  attr :prefix, :string, required: true
  attr :space, :map, required: true
  attr :icon, :string, default: nil
  attr :tree, :list, required: true
  attr :home, :map, default: nil
  attr :page_count, :integer, required: true
  attr :generated, :string, required: true
  attr :mirror_name, :string, required: true
  attr :mirror_url, :string, default: nil
  attr :html_attributes, :map, default: %{}

  def space(assigns) do
    ~H"""
    <.shell
      title={@title}
      prefix={@prefix}
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      html_attributes={@html_attributes}
      note={"#{plural(@page_count, "page")}, copied #{@generated}."}
      crumbs={[%{title: "All spaces", href: @prefix <> "index.html"}]}
    >
      <:nav>
        <p class="mb-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-base-content/70">
          <span class="truncate">{@space.name}</span>
          <span class="badge badge-ghost badge-xs">{@space.key}</span>
        </p>
        <.tree nodes={@tree} />
        <.labels_link prefix={@prefix} />
      </:nav>

      <header class="flex flex-wrap items-start gap-3">
        <img
          :if={@icon}
          src={@icon}
          alt=""
          loading="lazy"
          class="size-10 shrink-0 rounded-lg border border-base-300/60 bg-base-100 p-1"
        />
        <div class="min-w-0">
          <h1 class="text-2xl font-semibold tracking-tight">{@space.name}</h1>
          <p class="mt-1 text-xs uppercase tracking-wide text-base-content/70">
            {@space.key} · {plural(@page_count, "page")}
          </p>
        </div>
      </header>

      <p :if={@space.description not in [nil, ""]} class="mt-3 max-w-3xl text-sm">
        {@space.description}
      </p>

      <p :if={@space.labels not in [nil, []]} class="mt-3 flex flex-wrap items-center gap-1">
        <span class="text-[11px] font-medium uppercase tracking-wider text-base-content/70">
          Categories
        </span>
        <span :for={label <- @space.labels} class="badge badge-outline badge-xs">{label}</span>
      </p>

      <p :if={@home} class="mt-4 text-sm">
        Start at <a href={@home.href} class="link link-primary font-medium">{@home.title}</a>.
      </p>

      <nav aria-label="Pages in this space" class="mt-6 border-t border-base-300/70 pt-4">
        <h2 class="mb-3 text-sm font-semibold">All pages</h2>
        <.outline nodes={@tree} />
      </nav>
    </.shell>
    """
  end

  @doc """
  One page of the archive: its body, its place in the space and its files.

  `:page` is the mirrored page; `:body` the HTML already rewritten for the
  archive; `:attachments` are `%{name, href, size}` rows; `:children` and
  `:crumbs` are `%{title, href}` maps; `:path` is the trail from the space's
  root down to this page's parent; `:original` is the Confluence URL.

  The navigation is that trail, not the space's whole page tree: a tree in
  every page makes the archive quadratic — a space of 900 pages would carry its
  whole tree 900 times — so the tree lives once, on the space's front page.
  """
  attr :title, :string, required: true
  attr :prefix, :string, required: true
  attr :page, :map, required: true
  attr :body, :string, required: true
  attr :updated, :string, default: nil
  attr :space_name, :string, required: true
  attr :space_key, :string, required: true
  attr :space_href, :string, required: true
  attr :path, :list, default: []
  attr :children, :list, default: []
  attr :crumbs, :list, default: []
  attr :attachments, :list, default: []
  attr :comments, :list, default: []
  attr :comment_count, :integer, default: 0
  attr :original, :string, default: nil
  attr :markdown_href, :string, required: true
  attr :generated, :string, required: true
  attr :mirror_name, :string, required: true
  attr :mirror_url, :string, default: nil
  attr :html_attributes, :map, default: %{}

  def page(assigns) do
    ~H"""
    <.shell
      title={@title}
      prefix={@prefix}
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      html_attributes={@html_attributes}
      note={"Copied #{@generated} from the Confluence mirror."}
      crumbs={@crumbs}
    >
      <:nav>
        <p class="mb-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-base-content/70">
          <a href={@space_href} class="truncate hover:text-primary">{@space_name}</a>
          <span class="badge badge-ghost badge-xs">{@space_key}</span>
        </p>
        <a
          href={@space_href}
          class="mb-3 block text-[11px] font-medium text-primary hover:underline"
        >
          All pages in {@space_key} →
        </a>
        <ol class="space-y-1 text-xs">
          <li :for={node <- @path}>
            <a href={node.href} class="block truncate text-base-content/70 hover:text-primary">
              {node.title}
            </a>
          </li>
          <li class="truncate font-medium" aria-current="page">{@page.title}</li>
        </ol>
        <.labels_link prefix={@prefix} />
      </:nav>

      <article>
        <header>
          <p class="text-xs font-medium uppercase tracking-wider text-base-content/70">
            {@space_name}
          </p>
          <h1 class="mt-1 text-2xl font-semibold tracking-tight">{@page.title}</h1>
          <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/70">
            <span :if={@page.type == "blogpost"} class="badge badge-ghost badge-xs">Blog post</span>
            <span :if={@page.subtype == "live"} class="badge badge-ghost badge-xs">Live doc</span>
            <span :if={@page.status == "archived"} class="badge badge-warning badge-xs">
              Archived
            </span>
            <span :if={@page.status == "draft"} class="badge badge-info badge-xs">Draft</span>
            <span :if={Publishing.byline(@page.author_name)}>by {@page.author_name}</span>
            <span :if={@updated}>updated {@updated}</span>
            <span>version {@page.version_number}</span>
            <a :if={@original} href={@original} class="link link-primary">Original on Confluence</a>
            <a href={@markdown_href} download class="link">Markdown</a>
          </div>
          <p :if={@page.labels not in [nil, []]} class="mt-2 flex flex-wrap gap-1">
            <a
              :for={label <- @page.labels}
              href={@prefix <> Site.label_path(label)}
              class="badge badge-outline badge-xs hover:border-primary/50 hover:bg-base-200/50"
              title={"Everything labelled #{label}"}
            >
              {label}
            </a>
          </p>
        </header>

        <div class="confluence-content mt-4">
          {Phoenix.HTML.raw(@body)}
        </div>

        <nav
          :if={@children != []}
          aria-label="Child pages"
          class="mt-8 border-t border-base-300/70 pt-4"
        >
          <h2 class="mb-3 text-sm font-semibold">Child pages</h2>
          <ul class="divide-y divide-base-300/60 overflow-hidden rounded-xl border border-base-300/70 bg-base-100">
            <li :for={child <- @children}>
              <a
                href={child.href}
                class="flex min-h-11 items-center gap-2 px-3 py-2 text-sm transition hover:bg-base-200/40"
              >
                {child.title}
              </a>
            </li>
          </ul>
        </nav>
        <section id="comments" class="mt-8 border-t border-base-300/70 pt-4">
          <h2 class="mb-4 flex items-center gap-2 text-sm font-semibold">
            Comments <span class="badge badge-ghost badge-sm">{@comment_count}</span>
          </h2>
          <p :if={@comments == []} class="text-sm text-base-content/70">
            No comments on the original page.
          </p>
          <div class="space-y-5">
            <article :for={comment <- @comments} class="flex gap-3">
              <span class="mt-0.5 grid size-8 shrink-0 place-items-center rounded-full bg-base-200 text-xs font-semibold text-base-content/70">
                {initial(comment.author)}
              </span>
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-baseline gap-2">
                  <span class="text-sm font-medium">{comment.author}</span>
                  <span :if={comment.at} class="text-[11px] text-base-content/70">
                    {comment.at}
                  </span>
                </div>
                <div class="confluence-content mt-1 text-sm">
                  {Phoenix.HTML.raw(comment.body)}
                </div>
                <div
                  :for={reply <- comment.replies}
                  class="mt-3 flex gap-3 border-l-2 border-base-300/70 pl-3"
                >
                  <span class="mt-0.5 grid size-6 shrink-0 place-items-center rounded-full bg-base-200 text-[10px] font-semibold text-base-content/70">
                    {initial(reply.author)}
                  </span>
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-baseline gap-2">
                      <span class="text-xs font-medium">{reply.author}</span>
                      <span :if={reply.at} class="text-[10px] text-base-content/70">
                        {reply.at}
                      </span>
                    </div>
                    <div class="confluence-content mt-1 text-sm">
                      {Phoenix.HTML.raw(reply.body)}
                    </div>
                  </div>
                </div>
              </div>
            </article>
          </div>
        </section>
      </article>

      <:rail>
        <section>
          <h2 class="mb-2 text-xs font-semibold uppercase tracking-wider text-base-content/70">
            Page info
          </h2>
          <dl class="space-y-1 text-xs">
            <div class="flex gap-2">
              <dt class="w-24 shrink-0 text-base-content/70">Space</dt>
              <dd class="min-w-0 truncate">{@space_name} ({@space_key})</dd>
            </div>
            <div class="flex gap-2">
              <dt class="w-24 shrink-0 text-base-content/70">Confluence id</dt>
              <dd>{@page.confluence_id}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="w-24 shrink-0 text-base-content/70">Updated</dt>
              <dd>{@updated || "unknown"}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="w-24 shrink-0 text-base-content/70">Comments</dt>
              <dd>{@comment_count}</dd>
            </div>
          </dl>
        </section>

        <section :if={@attachments != []}>
          <h2 class="mb-2 text-xs font-semibold uppercase tracking-wider text-base-content/70">
            Attachments
          </h2>
          <ul class="space-y-1 text-xs">
            <li :for={attachment <- @attachments} class="flex min-w-0 items-baseline gap-2">
              <a href={attachment.href} class="truncate link link-primary">{attachment.name}</a>
              <span class="ml-auto shrink-0 text-[11px] text-base-content/70">
                {attachment.size}
              </span>
            </li>
          </ul>
        </section>
      </:rail>
    </.shell>
    """
  end

  @doc """
  The archive's search page.

  The index is a script file, not an inline block: a site of a hundred thousand
  pages makes an index that would have to be built, copied and parsed as part of
  one HTML string, and `file://` refuses to *fetch* a sibling file while it
  happily runs one. `assets/search.json` carries the same documents for other
  tools.
  """
  attr :title, :string, required: true
  attr :spaces, :list, required: true
  attr :page_count, :integer, required: true
  attr :generated, :string, required: true
  attr :mirror_name, :string, required: true
  attr :mirror_url, :string, default: nil
  attr :html_attributes, :map, default: %{}

  def search(assigns) do
    ~H"""
    <.shell
      title={@title}
      prefix=""
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      html_attributes={@html_attributes}
      note={"#{plural(@page_count, "page")} in #{plural(length(@spaces), "space")}, copied #{@generated}."}
    >
      <:nav>
        <p class="mb-3 text-xs font-semibold uppercase tracking-wider text-base-content/70">
          Spaces
        </p>
        <ul class="menu menu-sm w-full gap-1 p-0">
          <li :for={space <- @spaces}>
            <a href={space.href} class="truncate">
              {space.name}
              <span class="badge badge-ghost badge-xs">{space.key}</span>
            </a>
          </li>
        </ul>
        <.labels_link prefix="" />
      </:nav>

      <h1 class="text-2xl font-semibold tracking-tight">Search this copy</h1>
      <p class="mt-1 max-w-2xl text-sm text-base-content/70">
        Titles, spaces, labels and the beginning of each page's text. The index is part of the
        folder, so nothing is sent anywhere and search works offline.
      </p>

      <div class="mt-4 max-w-xl">
        <input
          id="search-q"
          type="search"
          autocomplete="off"
          spellcheck="false"
          autofocus
          placeholder="e.g. release notes"
          aria-label="Search this copy"
          class="input input-bordered w-full rounded-lg bg-base-100"
        />
      </div>

      <div class="mt-3 flex items-center gap-2">
        <span
          id="search-spinner"
          hidden
          aria-hidden="true"
          class="loading loading-spinner loading-xs text-primary"
        ></span>
        <p id="search-progress" aria-hidden="true" class="text-xs text-base-content/70"></p>
        <p id="search-status" role="status" class="text-xs text-base-content/70"></p>
      </div>
      <ol id="search-results" aria-label="Results" aria-busy="false" class="mt-3 space-y-2"></ol>

      <script src="assets/search-index.js" defer>
      </script>
      <script src="assets/search.js" defer>
      </script>
    </.shell>
    """
  end

  @doc """
  The label catalogue: every label the archive carries, with what it holds.

  `:labels` are `%{name, href, count, spaces}` maps.
  """
  attr :title, :string, required: true
  attr :prefix, :string, required: true
  attr :spaces, :list, required: true
  attr :labels, :list, required: true
  attr :generated, :string, required: true
  attr :mirror_name, :string, required: true
  attr :mirror_url, :string, default: nil
  attr :html_attributes, :map, default: %{}

  def labels(assigns) do
    ~H"""
    <.shell
      title={@title}
      prefix={@prefix}
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      html_attributes={@html_attributes}
      note={"#{plural(length(@labels), "label")}, copied #{@generated}."}
    >
      <:nav>
        <p class="mb-3 text-xs font-semibold uppercase tracking-wider text-base-content/70">
          Spaces
        </p>
        <ul class="menu menu-sm w-full gap-1 p-0">
          <li :for={space <- @spaces}>
            <a href={space.href} class="truncate">
              {space.name}
              <span class="badge badge-ghost badge-xs">{space.key}</span>
            </a>
          </li>
        </ul>
      </:nav>

      <h1 class="text-2xl font-semibold tracking-tight">Labels</h1>
      <p class="mt-1 max-w-2xl text-sm text-base-content/70">
        A way into the archive the page tree cannot give: everything about one subject,
        whichever space it lives in.
      </p>

      <ul class="mt-5 flex flex-wrap gap-2">
        <li :for={label <- @labels}>
          <a
            href={label.href}
            class="inline-flex items-center gap-1.5 rounded-lg border border-base-300/70 bg-base-100 px-2.5 py-1.5 text-xs transition hover:border-primary/40 hover:bg-base-200/40"
          >
            <span class="font-medium">{label.name}</span>
            <span class="badge badge-ghost badge-xs">{label.count}</span>
            <span class="text-[10px] uppercase tracking-wide text-base-content/70">
              {plural(label.spaces, "space")}
            </span>
          </a>
        </li>
      </ul>

      <p :if={@labels == []} class="mt-4 text-sm text-base-content/70">
        No page in this copy carries a label.
      </p>
    </.shell>
    """
  end

  @doc "Everything carrying one label."
  attr :title, :string, required: true
  attr :prefix, :string, required: true
  attr :spaces, :list, required: true
  attr :label, :string, required: true
  attr :pages, :list, required: true
  attr :generated, :string, required: true
  attr :mirror_name, :string, required: true
  attr :mirror_url, :string, default: nil
  attr :html_attributes, :map, default: %{}

  def label(assigns) do
    ~H"""
    <.shell
      title={@title}
      prefix={@prefix}
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      html_attributes={@html_attributes}
      note={"Copied #{@generated}."}
      crumbs={[%{title: "All labels", href: @prefix <> "labels/index.html"}]}
    >
      <:nav>
        <p class="mb-3 text-xs font-semibold uppercase tracking-wider text-base-content/70">
          Spaces
        </p>
        <ul class="menu menu-sm w-full gap-1 p-0">
          <li :for={space <- @spaces}>
            <a href={space.href} class="truncate">
              {space.name}
              <span class="badge badge-ghost badge-xs">{space.key}</span>
            </a>
          </li>
        </ul>
      </:nav>

      <h1 class="text-2xl font-semibold tracking-tight">{@label}</h1>
      <p class="mt-1 text-xs uppercase tracking-wide text-base-content/70">
        {plural(length(@pages), "page")} in {plural(
          @pages |> Enum.map(& &1.space_key) |> Enum.uniq() |> length(),
          "space"
        )}
      </p>

      <ul class="mt-4 divide-y divide-base-300/60 overflow-hidden rounded-xl border border-base-300/70 bg-base-100">
        <li :for={page <- @pages}>
          <a
            href={page.href}
            class="flex min-h-11 items-baseline gap-2 px-3 py-2 text-sm transition hover:bg-base-200/40"
          >
            <span class="truncate">{page.title}</span>
            <span class="ml-auto flex shrink-0 items-baseline gap-2">
              <span class="text-[11px] text-base-content/70">{page.space_name}</span>
              <span class="badge badge-ghost badge-xs">{page.space_key}</span>
            </span>
          </a>
        </li>
      </ul>
    </.shell>
    """
  end

  # ---------------------------------------------------------------------------
  # Shell
  # ---------------------------------------------------------------------------

  attr :title, :string, required: true
  attr :prefix, :string, required: true
  attr :mirror_name, :string, required: true
  attr :mirror_url, :string, default: nil
  attr :html_attributes, :map, default: %{}
  attr :note, :string, default: ""
  attr :crumbs, :list, default: []

  slot :nav
  slot :rail
  slot :inner_block, required: true

  defp shell(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html
      lang={assigns[:site_lang] || ConfluencePhxMirror.SiteSettings.lang() || "en"}
      {@html_attributes}
      class="scroll-smooth"
    >
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="color-scheme" content="light dark" />
        <meta name="generator" content="Confluence mirror static export" />
        <title>{@title}</title>
        <link rel="icon" href={@prefix <> "assets/favicon.ico"} />
        <link rel="stylesheet" href={@prefix <> "assets/site.css"} />
        <script src={@prefix <> "assets/theme.js"}>
        </script>
      </head>
      <body class="min-h-screen bg-base-100 text-base-content antialiased">
        <div class="flex min-h-screen flex-col">
          <header data-print="hide" class="border-b border-base-300/70 bg-base-100 print:hidden">
            <div class="mx-auto flex w-full max-w-[1600px] flex-wrap items-center gap-2 px-3 py-2 sm:flex-nowrap sm:gap-3 sm:px-5">
              <button
                type="button"
                data-site-sidebar-toggle
                aria-controls="site-sidebar"
                aria-expanded="true"
                aria-label="Hide the page tree"
                title="Hide the page tree"
                class="group -ml-1 grid size-11 shrink-0 place-items-center rounded-lg text-base-content/70 transition hover:bg-base-200 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 lg:size-9"
              >
                <svg
                  aria-hidden="true"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  class="size-5 group-aria-expanded:hidden"
                >
                  <rect x="3" y="3" width="18" height="18" rx="2" />
                  <path d="M9 3v18" />
                  <path d="m14 9 3 3-3 3" />
                </svg>
                <svg
                  aria-hidden="true"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  class="hidden size-5 group-aria-expanded:block"
                >
                  <rect x="3" y="3" width="18" height="18" rx="2" />
                  <path d="M9 3v18" />
                  <path d="m16 15-3-3 3-3" />
                </svg>
              </button>
              <a
                href={@prefix <> "index.html"}
                class="flex items-center gap-2.5 rounded-lg px-1 py-1 transition hover:bg-base-200/70"
              >
                <span class="grid size-8 place-items-center rounded-lg bg-primary font-bold text-primary-content">
                  {initial(@mirror_name)}
                </span>
                <span class="flex flex-col leading-tight">
                  <span class="text-sm font-semibold">{@mirror_name}</span>
                  <span class="max-sm:hidden text-[11px] uppercase tracking-wide text-base-content/70">
                    static copy
                  </span>
                </span>
              </a>
              <form
                action={@prefix <> "search.html"}
                method="get"
                role="search"
                class="flex min-w-0 items-center max-sm:order-last max-sm:w-full sm:ml-auto sm:flex-1 sm:justify-end"
              >
                <input
                  type="search"
                  name="q"
                  placeholder="Search this copy"
                  aria-label="Search this copy"
                  autocomplete="off"
                  class="input input-sm w-full rounded-lg bg-base-100 sm:w-48"
                />
              </form>
              <button
                type="button"
                data-site-theme
                aria-label="Theme: system"
                title="Theme: system"
                class="grid size-9 shrink-0 place-items-center rounded-lg text-base-content/70 transition hover:bg-base-200 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
              >
                <svg
                  aria-hidden="true"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  class="size-5"
                >
                  <circle cx="12" cy="12" r="4" />
                  <path d="M12 2v2m0 16v2M4.9 4.9l1.4 1.4m11.4 11.4 1.4 1.4M2 12h2m16 0h2M4.9 19.1l1.4-1.4m11.4-11.4 1.4-1.4" />
                </svg>
              </button>
            </div>
            <div
              :if={@crumbs != []}
              class="mx-auto flex w-full max-w-[1600px] flex-wrap items-center gap-2 px-3 pb-2 text-xs sm:px-5"
            >
              <%= for {crumb, index} <- Enum.with_index(@crumbs) do %>
                <span :if={index > 0} aria-hidden="true" class="text-base-content/40">/</span>
                <a href={crumb.href} class="text-base-content/70 hover:text-primary">
                  {crumb.title}
                </a>
              <% end %>
            </div>
          </header>

          <div
            data-site-backdrop
            hidden
            aria-hidden="true"
            class="fixed inset-0 z-40 bg-base-content/40 backdrop-blur-sm lg:hidden"
          >
          </div>

          <div class="mx-auto flex w-full max-w-[1600px] flex-1 items-stretch">
            <aside
              id="site-sidebar"
              tabindex="-1"
              aria-label="Navigation"
              data-print="hide"
              class="fixed inset-y-0 left-0 z-50 w-72 max-w-[85vw] -translate-x-full overflow-y-auto overscroll-contain border-r border-base-300/60 bg-base-100 shadow-lg transition-transform duration-200 focus:outline-none motion-reduce:transition-none data-[open]:translate-x-0 print:hidden lg:static lg:z-auto lg:w-72 lg:max-w-none lg:translate-x-0 lg:bg-base-200/25 lg:shadow-none lg:data-[collapsed]:hidden"
            >
              <div class="p-4 lg:sticky lg:top-[57px] lg:max-h-[calc(100vh-57px)] lg:overflow-y-auto">
                {render_slot(@nav)}
              </div>
            </aside>

            <main class="min-w-0 flex-1">
              <div class="w-full max-w-[88rem] px-4 py-5 sm:px-8 print:max-w-none print:p-0">
                {render_slot(@inner_block)}
              </div>
            </main>

            <aside
              :if={@rail != []}
              data-print="hide"
              class="hidden w-80 shrink-0 space-y-5 border-l border-base-300/60 p-5 print:hidden xl:block"
            >
              {render_slot(@rail)}
            </aside>
          </div>

          <footer data-print="hide" class="border-t border-base-300/70 bg-base-200/30 print:hidden">
            <div class="mx-auto flex w-full max-w-[1600px] flex-col gap-1 px-4 py-5 text-xs text-base-content/70 sm:flex-row sm:items-center sm:justify-between sm:px-6">
              <span class="flex flex-wrap items-center gap-2">
                <span class="font-medium text-base-content/80">{@mirror_name}</span>
                <a
                  :if={@mirror_url}
                  href={@mirror_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-primary hover:underline"
                >
                  The live site
                </a>
              </span>
              <span>{@note}</span>
            </div>
          </footer>
        </div>
        <script src={@prefix <> "assets/site.js"} defer>
        </script>
      </body>
    </html>
    """
  end

  # ---------------------------------------------------------------------------
  # Navigation
  # ---------------------------------------------------------------------------

  attr :nodes, :list, required: true
  attr :current, :integer, default: nil

  defp tree(assigns) do
    ~H"""
    <ul class="menu menu-sm w-full gap-0.5 p-0">
      <li :for={node <- @nodes}>
        <a
          href={node.href}
          class={["truncate", node.confluence_id == @current && "menu-active"]}
          aria-current={if node.confluence_id == @current, do: "page"}
        >
          {node.title}
        </a>
        <.tree :if={node.children != []} nodes={node.children} current={@current} />
      </li>
    </ul>
    """
  end

  attr :nodes, :list, required: true

  defp outline(assigns) do
    ~H"""
    <ul class="space-y-1 text-sm">
      <li :for={node <- @nodes}>
        <a href={node.href} class="link link-hover">{node.title}</a>
        <div :if={node.children != []} class="ml-3 border-l border-base-300/60 pl-3">
          <.outline nodes={node.children} />
        </div>
      </li>
    </ul>
    """
  end

  attr :prefix, :string, required: true

  defp labels_link(assigns) do
    ~H"""
    <a
      href={@prefix <> "labels/index.html"}
      class="mt-3 block text-[11px] font-medium text-primary hover:underline"
    >
      All labels →
    </a>
    """
  end

  defp plural(1, word), do: "1 " <> word
  defp plural(count, word), do: "#{count} #{word}s"

  defp initial(name) do
    name
    |> to_string()
    |> String.first()
    |> case do
      nil -> "?"
      first -> String.upcase(first)
    end
  end
end
