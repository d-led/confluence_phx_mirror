defmodule ConfluencePhxMirrorWeb.CatalogLive do
  @moduledoc """
  The browsable catalogs: the space directory, the people and label indexes, and
  a space's pages, blog posts and attachments.

  They share one LiveView because they answer one question — "show me the
  entries matching what I typed" — and therefore need one filter box, one URL
  shape (`?q=…&offset=…`) and one way of asking for the next page. Only the rows
  differ, and those live in `ConfluencePhxMirrorWeb.CatalogComponents`.

  Filtering and paging happen in the database (`ConfluencePhxMirror.Catalog`),
  so typing into a catalog with thousands of spaces costs one query and sends
  one page of rows.

  A space that is not mirrored — or that the reader may not see — navigates to
  the space overview, whose controller answers with a proper 404 rather than a
  catalog that quietly pretends to be empty.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.CatalogComponents
  import ConfluencePhxMirrorWeb.MirrorComponents, only: [space_tabs: 1]

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Catalog
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs

  # One page of a catalog. `?limit=` cannot raise it: a catalog is a browse view,
  # not an export.
  @page_size 50
  @debounce 220

  @directories [:spaces, :people, :labels]

  @impl true
  def mount(_params, _session, socket) do
    copy = copy(socket.assigns.live_action, nil, "")

    {:ok,
     assign(socket,
       kind: socket.assigns.live_action,
       q: "",
       offset: 0,
       items: [],
       more?: false,
       space: nil,
       tree: [],
       breadcrumbs: [],
       form: to_form(%{"q" => ""}, as: :filter),
       copy: copy,
       page_title: copy.page_title,
       sort: "title",
       debounce: @debounce
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = socket.assigns.kind

    case catalog_space(kind, params, socket) do
      {:ok, space} ->
        q = filter_text(params["q"])
        offset = offset(params["offset"])
        sort = sort_of(params["sort"])

        %{items: items, more?: more?} =
          entries(kind, socket, space, q: q, offset: offset, limit: @page_size, sort: sort)

        copy = copy(kind, space, q)

        {:noreply,
         assign(socket,
           q: q,
           offset: offset,
           space: space,
           items: items,
           more?: more?,
           tree: tree(space),
           breadcrumbs: breadcrumbs(space),
           copy: copy,
           page_title: copy.page_title,
           sort: sort,
           form: to_form(%{"q" => q}, as: :filter)
         )}

      {:error, key} ->
        {:noreply, push_navigate(socket, to: URLs.space_overview_path(key), replace: true)}
    end
  end

  @impl true
  def handle_event("filter", %{"filter" => %{"q" => q}}, socket) do
    {:noreply, show(socket, filter_text(q), 0)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, show(socket, "", 0)}
  end

  def handle_event("more", _params, socket) do
    {:noreply, show(socket, socket.assigns.q, socket.assigns.offset + @page_size)}
  end

  def handle_event("sort", %{"sort" => sort}, socket) do
    {:noreply,
     socket
     |> assign(:sort, sort_of(sort))
     |> show(socket.assigns.q, 0)}
  end

  def handle_event("previous", _params, socket) do
    {:noreply, show(socket, socket.assigns.q, max(socket.assigns.offset - @page_size, 0))}
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

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
      space={@space}
      tree={@tree}
      breadcrumbs={@breadcrumbs}
      rail?={false}
      page_title={@copy.page_title}
    >
      <header class="border-b border-base-300/70 pb-4">
        <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-primary">
          {@copy.eyebrow}
        </p>
        <h1 class="mt-1 text-2xl font-semibold leading-tight sm:text-3xl">{@copy.title}</h1>
        <p class="mt-2 max-w-2xl text-sm leading-relaxed text-base-content/65">{@copy.blurb}</p>
      </header>

      <div :if={@space} class="mt-4 border-b border-base-300/70">
        <.space_tabs space={@space} active={@kind} />
      </div>

      <.catalog_filter
        form={@form}
        q={@q}
        placeholder={@copy.placeholder}
        count={length(@items)}
        singular={@copy.singular}
        plural={@copy.plural}
        more?={@more?}
        debounce={@debounce}
      />

      <.catalog_empty :if={@items == []} empty={@copy.empty} />
      <.catalog_body
        :if={@items != []}
        kind={@kind}
        items={@items}
        space={@space}
        sort={@sort}
      />
      <.catalog_pager
        more?={@more?}
        previous?={@offset > 0}
        offset={@offset}
        count={length(@items)}
      />
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # What the catalog holds
  # ---------------------------------------------------------------------------

  # Every catalog but the directories is scoped to one space, which the route
  # names by key.
  defp catalog_space(kind, _params, _socket) when kind in @directories, do: {:ok, nil}

  defp catalog_space(_kind, %{"key" => key}, socket) do
    with {:ok, space} <- Mirror.find_space(key),
         true <- Authorization.can_read_space?(scope(socket), space) do
      {:ok, space}
    else
      _other -> {:error, key}
    end
  end

  defp entries(:spaces, socket, _space, opts), do: Catalog.spaces(scope(socket), opts)
  defp entries(:people, _socket, _space, opts), do: Catalog.people(opts)
  defp entries(:labels, _socket, _space, opts), do: Catalog.labels(opts)

  defp entries(:pages, _socket, space, opts) do
    Catalog.contents(space, Keyword.update!(opts, :sort, &order/1))
  end

  defp entries(:blog, _socket, space, opts),
    do:
      Catalog.contents(
        space,
        Keyword.merge([type: "blogpost", sort: :recent], Keyword.delete(opts, :sort))
      )

  defp entries(:attachments, _socket, space, opts), do: Catalog.attachments(space, opts)

  defp tree(nil), do: []
  defp tree(space), do: Mirror.tree(space.id)

  defp breadcrumbs(nil), do: []
  defp breadcrumbs(space), do: [%{title: space.name, path: URLs.space_path(space.key)}]

  # ---------------------------------------------------------------------------
  # The URL
  # ---------------------------------------------------------------------------

  defp show(socket, q, offset) do
    push_patch(socket, to: catalog_path(socket, q, offset), replace: true)
  end

  defp catalog_path(socket, q, offset) do
    params =
      [
        {"q", q},
        {"offset", if(offset > 0, do: Integer.to_string(offset))},
        {"sort", if(socket.assigns.sort == "updated", do: "updated")}
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    case params do
      [] -> base_path(socket)
      params -> base_path(socket) <> "?" <> URI.encode_query(params)
    end
  end

  defp base_path(socket) do
    case {socket.assigns.kind, socket.assigns.space} do
      {:spaces, _} -> ~p"/spaces"
      {:people, _} -> ~p"/people"
      {:labels, _} -> ~p"/labels"
      {:pages, space} -> URLs.space_pages_path(space.key)
      {:blog, space} -> URLs.space_blog_path(space.key)
      {:attachments, space} -> URLs.space_attachments_path(space.key)
    end
  end

  defp filter_text(nil), do: ""
  defp filter_text(value), do: value |> to_string() |> String.trim()

  defp sort_of("updated"), do: "updated"
  defp sort_of(_sort), do: "title"

  defp order(:title), do: :title
  defp order(:updated), do: :recent

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset > 0 -> offset
      _other -> 0
    end
  end

  defp offset(_value), do: 0

  defp scope(socket), do: socket.assigns.current_scope || Scope.for_user(nil)

  # ---------------------------------------------------------------------------
  # Words on the page
  # ---------------------------------------------------------------------------

  defp copy(:spaces, _space, q) do
    %{
      eyebrow: "Directory",
      title: "Spaces",
      page_title: "Spaces",
      blurb:
        "Every Confluence space mirrored here, with its content counts. Start typing to narrow the list — each word has to appear in the name, the key or the description.",
      placeholder: "Filter by name, key or description",
      singular: "space",
      plural: "spaces",
      empty:
        empty(
          q,
          "No spaces mirrored yet",
          "An administrator can fill the mirror by running a sync."
        )
    }
  end

  defp copy(:people, _space, q) do
    %{
      eyebrow: "Directory",
      title: "People",
      page_title: "People",
      blurb:
        "Authors of mirrored content. The mirror lists the bylines it synced from Confluence; it does not keep a separate user directory.",
      placeholder: "Filter by name",
      singular: "person",
      plural: "people",
      empty: empty(q, "No authors yet", "Sync a space and its authors appear here.")
    }
  end

  defp copy(:labels, _space, q) do
    %{
      eyebrow: "Browse",
      title: "Labels",
      page_title: "Labels",
      blurb:
        "Labels come from Confluence and are indexed for search (label = incident filters by label).",
      placeholder: "Filter labels",
      singular: "label",
      plural: "labels",
      empty: empty(q, "No labels yet", "Sync a space whose pages carry labels.")
    }
  end

  defp copy(:pages, space, q) do
    %{
      eyebrow: space_name(space),
      title: "Pages",
      page_title: "Pages",
      blurb:
        "Every page in the space, archived ones included — they stay readable and searchable, Confluence only hides them from the page tree.",
      placeholder: "Filter by title or author",
      singular: "page",
      plural: "pages",
      empty: empty(q, "Nothing in this space yet", "Sync the space to mirror its pages.")
    }
  end

  defp copy(:blog, space, q) do
    %{
      eyebrow: space_name(space),
      title: "Blog",
      page_title: "Blog",
      blurb: "Blog posts from the space, newest first.",
      placeholder: "Filter by title or author",
      singular: "post",
      plural: "posts",
      empty: empty(q, "No blog posts", "This space has no mirrored blog posts yet.")
    }
  end

  defp copy(:attachments, space, q) do
    %{
      eyebrow: space_name(space),
      title: "Attachments",
      page_title: "Attachments",
      blurb: "Files attached to the space's pages, searchable by file name and by page title.",
      placeholder: "Filter by file name or page",
      singular: "file",
      plural: "files",
      empty: empty(q, "No attachments mirrored", "Sync the space to fetch its files.")
    }
  end

  defp space_name(nil), do: ""
  defp space_name(space), do: space.name

  defp empty("", title, body), do: %{icon: "hero-inbox", title: title, body: body}

  defp empty(q, _title, _body) do
    %{
      icon: "hero-magnifying-glass",
      title: "Nothing matches “#{q}”",
      body: "Every word has to appear in the entry. Try fewer or different words."
    }
  end
end
