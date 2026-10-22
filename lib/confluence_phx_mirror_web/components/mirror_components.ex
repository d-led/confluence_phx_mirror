defmodule ConfluencePhxMirrorWeb.MirrorComponents do
  @moduledoc """
  UI building blocks specific to the Confluence domain: page trees,
  breadcrumbs, labels, page metadata, attachments and comments.
  """

  use ConfluencePhxMirrorWeb, :html

  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirrorWeb.Time

  @doc """
  Breadcrumb trail from the space to the current page.

  Deep trails collapse in the middle: the root and the current page always stay
  visible, the immediate parent stays visible, and everything between moves
  into an ellipsis dropdown on narrow viewports while the full trail is shown
  inline from `lg` up. It is pure CSS (`<details>` + breakpoints), so the
  breadcrumb costs no JavaScript and survives without hydration.
  """
  attr :items, :list, required: true, doc: "list of %{title, path}, root first"
  attr :current, :string, default: nil

  def breadcrumbs(assigns) do
    items = trail(assigns.items, assigns.current)
    {head, middle, parent} = split_trail(items)

    assigns =
      assign(assigns,
        head: head,
        middle: middle,
        parent: parent,
        collapse?: length(middle) > 1
      )

    ~H"""
    <nav
      class="flex min-w-0 items-center gap-1 text-xs text-base-content/60"
      aria-label="Breadcrumb"
    >
      <.link navigate={~p"/"} class="rounded p-0.5 hover:text-primary" aria-label="Home">
        <.icon name="hero-home" class="size-3.5" />
      </.link>

      <span :if={@head} class="flex min-w-0 items-center gap-1">
        <.icon name="hero-chevron-right" class="size-3 shrink-0 opacity-40" />
        <.crumb item={@head} />
      </span>

      <span
        :if={@middle != [] and not @collapse?}
        class="flex min-w-0 items-center gap-1"
      >
        <span :for={item <- @middle} class="flex min-w-0 items-center gap-1">
          <.icon name="hero-chevron-right" class="size-3 shrink-0 opacity-40" />
          <.crumb item={item} />
        </span>
      </span>

      <%= if @collapse? do %>
        <span class="flex items-center gap-1 lg:hidden">
          <.icon name="hero-chevron-right" class="size-3 shrink-0 opacity-40" />
          <details class="dropdown">
            <summary
              class="cursor-pointer list-none rounded px-1 py-0.5 leading-none hover:bg-base-200 hover:text-primary"
              aria-label={"Show #{length(@middle)} hidden levels"}
            >
              …
            </summary>
            <ul class="menu dropdown-content z-50 mt-2 w-64 rounded-box border border-base-300 bg-base-100 p-2 text-xs shadow-lg">
              <li :for={item <- @middle}>
                <.link navigate={item.path} class="truncate">{item.title}</.link>
              </li>
            </ul>
          </details>
        </span>

        <span class="hidden min-w-0 items-center gap-1 lg:flex">
          <span :for={item <- @middle} class="flex min-w-0 items-center gap-1">
            <.icon name="hero-chevron-right" class="size-3 shrink-0 opacity-40" />
            <.crumb item={item} />
          </span>
        </span>
      <% end %>

      <span :if={@parent} class="flex min-w-0 items-center gap-1">
        <.icon name="hero-chevron-right" class="size-3 shrink-0 opacity-40" />
        <.crumb item={@parent} />
      </span>

      <span :if={@current} class="flex min-w-0 items-center gap-1">
        <.icon name="hero-chevron-right" class="size-3 shrink-0 opacity-40" />
        <span class="max-w-[22rem] truncate font-medium text-base-content/80" aria-current="page">
          {@current}
        </span>
      </span>
    </nav>
    """
  end

  attr :item, :map, required: true

  defp crumb(assigns) do
    ~H"""
    <.link navigate={@item.path} class="max-w-[16rem] truncate rounded p-0.5 hover:text-primary">
      {@item.title}
    </.link>
    """
  end

  # A space's home page carries the space's title, and a sub-page can repeat an
  # ancestor's name; either way the reader would see the same word twice in one
  # trail. Keep the first occurrence and drop the current title entirely.
  defp trail(items, current) do
    Enum.reduce(items, [], fn item, acc ->
      repeated? = item.title == current or Enum.any?(acc, &(&1.title == item.title))
      if repeated?, do: acc, else: acc ++ [item]
    end)
  end

  # Root stays first, the immediate parent stays next to the current page, and
  # everything between is what can be collapsed.
  defp split_trail([]), do: {nil, [], nil}

  defp split_trail([head | rest]) do
    case Enum.split(rest, -1) do
      {middle, []} -> {head, middle, nil}
      {middle, [parent]} -> {head, middle, parent}
    end
  end

  @doc "Recursive page tree for the sidebar."
  attr :nodes, :list, required: true, doc: "list of %{page: page, children: [...]}"
  attr :space_key, :string, required: true
  attr :current, :any, default: nil
  attr :depth, :integer, default: 0

  def page_tree(assigns) do
    ~H"""
    <ul
      id={@depth == 0 && "page-tree"}
      class={[
        "menu menu-sm w-full gap-0.5 p-0",
        @depth > 0 && "ml-3 border-l border-base-300/70 pl-2"
      ]}
    >
      <li :for={node <- @nodes}>
        <.link
          navigate={URLs.content_path(@space_key, node.page)}
          aria-current={@current && @current.id == node.page.id && "page"}
          title={node.page.title}
          class={[
            "flex min-h-9 items-center gap-2 rounded-md py-1.5 pr-2 text-[13px]",
            @current && @current.id == node.page.id && "bg-primary/10 font-semibold text-primary"
          ]}
        >
          <.icon
            name={if node.page.type == "blogpost", do: "hero-newspaper", else: "hero-document-text"}
            class="size-3.5 shrink-0 opacity-60"
          />
          <span class="truncate">{node.page.title}</span>
        </.link>
        <.page_tree
          :if={node.children != []}
          nodes={node.children}
          space_key={@space_key}
          current={@current}
          depth={@depth + 1}
        />
      </li>
    </ul>
    <p :if={@nodes == [] and @depth == 0} class="px-2 py-3 text-xs text-base-content/70">
      No pages in this space yet.
    </p>
    """
  end

  @doc "Label chips linking to the label browser."
  attr :labels, :list, required: true
  attr :class, :any, default: nil

  def label_chips(assigns) do
    ~H"""
    <div :if={@labels != []} class={["flex flex-wrap items-center gap-1.5", @class]}>
      <a
        :for={label <- @labels}
        href={URLs.label_path(label)}
        class="badge badge-outline badge-sm gap-1 border-base-300 normal-case text-base-content/70 transition hover:border-primary hover:text-primary"
      >
        <.icon name="hero-tag" class="size-3" /> {label}
      </a>
    </div>
    """
  end

  @doc "Author, timestamps, version, labels and the backlink to Confluence."
  attr :page, :map, required: true

  def page_meta(assigns) do
    ~H"""
    <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-base-content/60">
      <span class="inline-flex items-center gap-1">
        <.icon name="hero-user-circle" class="size-3.5" />
        {(@page.author_name || "Unknown author") |> to_string()}
      </span>
      <span
        class="inline-flex items-center gap-1"
        title={Time.datetime(@page.external_updated_at)}
      >
        <.icon name="hero-clock" class="size-3.5" /> Updated {Time.ago(@page.external_updated_at)}
      </span>
      <span class="inline-flex items-center gap-1">
        <.icon name="hero-code-bracket" class="size-3.5" /> v{@page.version_number}
      </span>
      <span class="inline-flex items-center gap-1" title={Time.datetime(@page.synced_at)}>
        <.icon name="hero-arrow-path" class="size-3.5" /> Synced {Time.ago(@page.synced_at)}
      </span>
      <a
        :if={@page.external_url}
        href={@page.external_url}
        target="_blank"
        rel="noopener noreferrer"
        class="inline-flex items-center gap-1 font-medium text-primary hover:underline"
      >
        <.icon name="hero-arrow-top-right-on-square" class="size-3.5" /> View original
      </a>
    </div>
    """
  end

  attr :status, :string, default: "current"
  attr :type, :string, default: "page"

  def badges(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-1.5">
      <span :if={@type == "blogpost"} class="badge badge-info badge-sm gap-1">
        <.icon name="hero-newspaper" class="size-3" /> Blog post
      </span>
      <span :if={@status == "archived"} class="badge badge-neutral badge-sm gap-1">
        <.icon name="hero-archive-box" class="size-3" /> Archived
      </span>
      <span :if={@status == "draft"} class="badge badge-warning badge-sm gap-1">
        <.icon name="hero-pencil-square" class="size-3" /> Draft
      </span>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :icon, :string, default: "hero-information-circle"
  attr :class, :any, default: nil

  slot :inner_block, required: true

  def rail_section(assigns) do
    ~H"""
    <section class={["rounded-xl border border-base-300/70 bg-base-100/60 p-4", @class]}>
      <h2 class="mb-2 flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/70">
        <.icon name={@icon} class="size-3.5" /> {@title}
      </h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :page, :map, required: true
  attr :attachments, :list, required: true

  def attachment_list(assigns) do
    ~H"""
    <div :if={@attachments == []} class="text-xs text-base-content/70">No attachments.</div>
    <ul :if={@attachments != []} class="space-y-2">
      <li :for={attachment <- @attachments} class="group flex items-center gap-2">
        <span class="grid size-7 shrink-0 place-items-center rounded-md bg-base-200 text-base-content/60">
          <.icon name={icon_for(attachment.media_type)} class="size-3.5" />
        </span>
        <a
          href={
            URLs.attachment_path(
              @page.space.key,
              @page.confluence_id,
              attachment.confluence_id,
              attachment.filename
            )
          }
          class="min-w-0 flex-1 truncate text-xs font-medium text-primary hover:underline"
          download={attachment.filename}
          title={attachment.filename}
        >
          {attachment.filename}
        </a>
        <span class="shrink-0 text-[10px] tabular-nums text-base-content/70">
          {ConfluencePhxMirror.Mirror.Attachment.human_size(attachment.byte_size)}
        </span>
      </li>
    </ul>
    """
  end

  defp icon_for(media_type) do
    cond do
      String.starts_with?(media_type || "", "image/") -> "hero-photo"
      String.contains?(media_type || "", "pdf") -> "hero-document"
      String.contains?(media_type || "", "csv") -> "hero-table-cells"
      String.contains?(media_type || "", "zip") -> "hero-archive-box"
      true -> "hero-paper-clip"
    end
  end

  attr :pages, :list, required: true
  attr :empty, :string, default: "Nothing here yet."

  def page_list(assigns) do
    ~H"""
    <p :if={@pages == []} class="text-xs text-base-content/70">{@empty}</p>
    <ul :if={@pages != []} class="space-y-2">
      <li :for={page <- @pages}>
        <.link
          navigate={URLs.page_path(page.space.key, page.confluence_id, page.slug)}
          class="group flex items-start gap-2"
        >
          <.icon
            name={if page.type == "blogpost", do: "hero-newspaper", else: "hero-document-text"}
            class="mt-0.5 size-3.5 shrink-0 text-base-content/70"
          />
          <span class="min-w-0">
            <span class="block truncate text-xs font-medium group-hover:text-primary">{page.title}</span>
            <span class="block text-[10px] text-base-content/70">
              {page.space.key} · {Time.ago(page.external_updated_at)}
            </span>
          </span>
        </.link>
      </li>
    </ul>
    """
  end

  attr :page, :map, required: true
  attr :comments, :list, required: true

  # Comment bodies go through Sync.Renderer, which strips scripts and event
  # handlers before they are stored, exactly like page bodies.
  # sobelow_skip ["XSS.Raw"]
  def comment_thread(assigns) do
    roots = Enum.filter(assigns.comments, &is_nil(&1.parent_id))
    replies = Enum.group_by(Enum.reject(assigns.comments, &is_nil(&1.parent_id)), & &1.parent_id)

    assigns = assign(assigns, roots: roots, replies: replies)

    ~H"""
    <section id="comments" class="mt-10 border-t border-base-300/70 pt-6">
      <h2 class="mb-4 flex items-center gap-2 text-sm font-semibold">
        <.icon name="hero-chat-bubble-left-right" class="size-4 text-base-content/70" /> Comments
        <span class="badge badge-ghost badge-sm">{length(@comments)}</span>
      </h2>
      <p :if={@comments == []} class="text-sm text-base-content/70">
        No comments on the original page.
      </p>
      <div class="space-y-5">
        <article :for={comment <- @roots} class="flex gap-3">
          <span class="mt-0.5 grid size-8 shrink-0 place-items-center rounded-full bg-base-200 text-xs font-semibold text-base-content/70">
            {initials(comment.author_name)}
          </span>
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-baseline gap-2">
              <span class="text-sm font-medium">{comment.author_name || "Anonymous"}</span>
              <span
                class="text-[11px] text-base-content/70"
                title={Time.datetime(comment.external_created_at)}
              >
                {Time.ago(comment.external_created_at)}
              </span>
            </div>
            <div class="confluence-content mt-1 text-sm">
              {Phoenix.HTML.raw(comment.body_export || "")}
            </div>
            <div
              :for={reply <- Map.get(@replies, comment.id, [])}
              class="mt-3 flex gap-3 border-l-2 border-base-300/70 pl-3"
            >
              <span class="mt-0.5 grid size-6 shrink-0 place-items-center rounded-full bg-base-200 text-[10px] font-semibold text-base-content/70">
                {initials(reply.author_name)}
              </span>
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-baseline gap-2">
                  <span class="text-xs font-medium">{reply.author_name}</span>
                  <span class="text-[10px] text-base-content/70">{Time.ago(reply.external_created_at)}</span>
                </div>
                <div class="confluence-content mt-1 text-sm">
                  {Phoenix.HTML.raw(reply.body_export || "")}
                </div>
              </div>
            </div>
          </div>
        </article>
      </div>
    </section>
    """
  end

  @doc "Two letters for the avatar bubble of an author."
  def initials(nil), do: "?"

  def initials(name) do
    name
    |> String.split(~r/[\s@._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      value -> value
    end
  end

  attr :icon, :string, default: "hero-magnifying-glass"
  attr :title, :string, required: true
  attr :body, :string, default: nil

  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class="rounded-xl border border-dashed border-base-300 bg-base-200/30 px-6 py-12 text-center">
      <div class="mx-auto grid size-11 place-items-center rounded-full bg-base-200 text-base-content/70">
        <.icon name={@icon} class="size-5" />
      </div>
      <h2 class="mt-3 text-sm font-semibold">{@title}</h2>
      <p :if={@body} class="mx-auto mt-1 max-w-md text-xs text-base-content/70">{@body}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :result, :map, required: true
  attr :terms, :list, default: []

  def search_hit(assigns) do
    ~H"""
    <article
      data-hit
      class="group relative rounded-xl border border-base-300/70 bg-base-100 p-4 transition hover:border-primary/40 hover:shadow-sm"
    >
      <div class="min-w-0">
        <.link
          navigate={URLs.page_path(@result.space.key, @result.page.confluence_id, @result.page.slug)}
          data-hit-link
          class="block min-w-0 text-base font-semibold text-base-content after:absolute after:inset-0 after:content-[''] group-hover:text-primary"
        >
          <span class="block truncate">{highlight(@result.page.title, @terms)}</span>
        </.link>
        <div class="mt-0.5 flex flex-wrap items-center gap-2 text-[11px] text-base-content/70">
          <span class="badge badge-ghost badge-xs">{@result.space.key}</span>
          <span>{@result.page.space.name}</span>
          <span aria-hidden="true">·</span>
          <span>Updated {Time.ago(@result.page.external_updated_at)}</span>
        </div>
      </div>
      <p class="mt-2 line-clamp-2 text-xs leading-relaxed text-base-content/65">
        {highlight(@result.snippet, @terms)}
      </p>
      <div class="relative z-10 mt-2"><.label_chips labels={@result.page.labels} /></div>
    </article>
    """
  end

  @doc """
  Escapes text and wraps query terms in `<mark>`.

  Terms only ever come from the query parser (letters/digits/underscore), and
  the text is escaped before highlighting, so this cannot inject markup.
  """
  def highlight(nil, _terms), do: ""

  # The text is escaped before any markup is added; only our own <mark> tags
  # are ever raw here, and search terms are escaped into them by the caller.
  # sobelow_skip ["XSS.Raw"]
  def highlight(text, terms) do
    escaped = text |> to_string() |> Plug.HTML.html_escape() |> IO.iodata_to_binary()

    pattern =
      terms
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(String.length(&1) < 2))
      |> Enum.map_join("|", &Regex.escape/1)

    if pattern == "" do
      Phoenix.HTML.raw(escaped)
    else
      ~r/(#{pattern})/iu
      |> Regex.replace(escaped, fn match ->
        ~s(<mark class="rounded bg-warning/40 px-0.5 text-inherit">#{match}</mark>)
      end)
      |> Phoenix.HTML.raw()
    end
  end

  attr :space, :map, required: true
  attr :active, :atom, required: true, doc: ":overview, :pages, :blog or :attachments"

  @doc "Confluence-style tabs shown on every space view."
  def space_tabs(assigns) do
    key = assigns.space.key

    assigns =
      assign(assigns,
        tabs: [
          {:overview, "Overview", URLs.space_overview_path(key)},
          {:pages, "Pages", URLs.space_pages_path(key)},
          {:blog, "Blog", URLs.space_blog_path(key)},
          {:attachments, "Attachments", URLs.space_attachments_path(key)}
        ]
      )

    ~H"""
    <nav class="-mb-px flex gap-1 overflow-x-auto" aria-label="Space sections">
      <.link
        :for={{id, label, path} <- @tabs}
        navigate={path}
        aria-current={id == @active && "page"}
        class={[
          "flex min-h-11 items-center border-b-2 px-3 text-sm transition sm:min-h-10",
          if(id == @active,
            do: "border-primary font-semibold text-primary",
            else:
              "border-transparent text-base-content/60 hover:border-base-300 hover:text-base-content"
          )
        ]}
      >
        {label}
      </.link>
    </nav>
    """
  end

  attr :space, :map, required: true
  attr :count, :integer, default: 0
  attr :blog_posts, :integer, default: nil
  attr :updated_at, :any, default: nil

  def space_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/spaces/#{@space.key}"}
      class="group flex h-full flex-col rounded-xl border border-base-300/70 bg-base-100 p-4 transition hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 motion-reduce:hover:translate-y-0"
    >
      <div class="flex items-center justify-between gap-2">
        <span class="badge badge-ghost badge-sm">{@space.key}</span>
        <span class="text-[11px] tabular-nums text-base-content/70">
          {@count} {if @count == 1, do: "page", else: "pages"}
        </span>
      </div>
      <span class="mt-2 text-sm font-semibold group-hover:text-primary">{@space.name}</span>
      <span class="mt-0.5 line-clamp-2 text-xs text-base-content/70">
        {@space.description || "No description."}
      </span>
      <span
        :if={@blog_posts not in [nil, 0]}
        class="mt-2 text-[11px] tabular-nums text-base-content/70"
      >
        {@blog_posts} {if @blog_posts == 1, do: "blog post", else: "blog posts"}
      </span>
      <span
        :if={@updated_at}
        class="mt-auto pt-3 text-[10px] uppercase tracking-wide text-base-content/70"
      >
        Updated {Time.ago(@updated_at)}
      </span>
    </.link>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  def kv(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-3 border-b border-base-300/50 py-1.5 last:border-0">
      <dt class="text-[11px] uppercase tracking-wide text-base-content/70">{@label}</dt>
      <dd class="min-w-0 truncate text-right text-xs font-medium">{@value}</dd>
    </div>
    """
  end
end
