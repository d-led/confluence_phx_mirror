defmodule ConfluencePhxMirror.Sync.Renderer do
  @moduledoc """
  Turns Confluence's `export_view` HTML into mirror-ready HTML.

  Confluence already renders macros in `export_view` (panels, code, expand,
  status, TOC, Jira issues, includes…), so the mirror keeps that markup
  verbatim. What this module changes is exactly the part that must change for
  a mirror:

    * links to mirrored pages become internal mirror links (cross-linking),
    * links to pages that were not mirrored stay absolute back to Confluence,
      so a reader can always open the original,
    * attachment links and images point at the mirrored blob,
    * active content (`script`, event handler attributes, `javascript:` URLs)
      is removed, because the mirror renders third-party HTML.

  Every rewritten link is returned as a link record so the sync can store
  backlinks. The renderer is pure: it never queries the database.
  """

  alias ConfluencePhxMirror.Mirror.URLs

  @type page_ref :: %{space_key: String.t(), confluence_id: integer(), slug: String.t()}

  @type attachment_ref :: %{
          confluence_id: integer(),
          page_confluence_id: integer(),
          space_key: String.t(),
          filename: String.t()
        }

  @type context :: %{
          required(:page) => ConfluencePhxMirror.Mirror.Page.t(),
          required(:space_key) => String.t(),
          required(:base_url) => String.t() | nil,
          optional(:pages) => %{integer() => page_ref()},
          optional(:attachments) => %{String.t() => attachment_ref()}
        }

  @type link :: %{
          href: String.t(),
          kind: String.t(),
          target_confluence_id: integer() | nil,
          label: String.t() | nil
        }

  @type result :: %{html: String.t(), links: [link()], text: String.t()}

  # iframe/object/embed are not stripped here: they are replaced by an honest
  # placeholder in `replace_live_only_content/2`, which runs later.
  @unsafe_elements ~w(script applet form input button)
  @url_attributes ~w(href src action formaction poster)

  # Macros Confluence renders in the browser (Jira issues, page tree, Connect
  # and Forge apps) do not survive the REST API: the export carries an iframe or
  # an unexpanded macro. A static mirror cannot run them, so it says so instead
  # of pretending — inventing output would be a lie about the source.
  @live_only_elements ~w(iframe object embed)

  @macro_labels %{
    "jira" => "a Jira issues search",
    "jiraissues" => "a Jira issues list",
    "jirachart" => "a Jira chart",
    "toc" => "a table of contents",
    "pagetree" => "a page tree",
    "children" => "a child pages list",
    "blog-posts" => "a blog posts list",
    "recently-updated" => "a recently updated list",
    "contentbylabel" => "a content by label list",
    "page-properties-report" => "a page properties report",
    "contributors" => "a contributors list",
    "tasks-report" => "a tasks report",
    "livesearch" => "a live search box",
    "gadget" => "an external gadget",
    "widget" => "an external widget"
  }

  # Floki's parser drops text runs that are only whitespace, but the exporter
  # relies on them for the visible space between inline elements (two status
  # lozenges would touch, `<strong>` next to `<em>` would read "onetwo").
  # Each run travels through the parse as a marker and comes back verbatim.
  @inter_tag_space ~r/(?<=>)\s+(?=<)/u
  @space_marker ~r/\x{E000}([A-Za-z0-9_-]+)\x{E001}/u

  @doc """
  Sanitises and rewrites `html` for `context`.

  Returns the rewritten HTML, the links found in it and its plain text.
  """
  @spec render(String.t() | nil, context()) :: result()
  def render(nil, _context), do: %{html: "", links: [], text: ""}
  def render("", _context), do: %{html: "", links: [], text: ""}

  def render(html, context) when is_binary(html) do
    nodes =
      html
      |> mark_spaces()
      |> Floki.parse_fragment!()
      |> remove_unsafe_elements()

    # Links are collected *before* rewriting, while hrefs still carry the
    # Confluence identity the link table needs.
    links =
      nodes
      |> Floki.find("a[href]")
      |> Enum.map(&link_record(&1, context))
      |> Enum.uniq()

    rewritten =
      nodes
      |> traverse_and_rewrite(context)
      |> replace_live_only_content(context)
      |> Floki.raw_html()
      |> restore_spaces()

    %{html: rewritten, links: links, text: plain_text(rewritten)}
  end

  @doc "Plain text of rendered HTML, used for Postgres full-text search."
  def plain_text(html) when is_binary(html) do
    html
    |> Floki.parse_fragment!()
    |> drop_text_excluded()
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def plain_text(_), do: ""

  # Confluence's `export_view` inlines its own colour rules in `<style>` blocks.
  # Those rules are kept in the rendered HTML (they style the page), but their
  # text content is not prose: leaving it in `body_text` puts
  # `[data-colorid=…]{color:#97a0af}` into previews and search snippets.
  @text_excluded_elements ~w(style script noscript head title template)

  defp drop_text_excluded(nodes) do
    Enum.reduce(@text_excluded_elements, nodes, &Floki.filter_out(&2, &1))
  end

  defp remove_unsafe_elements(nodes) do
    Enum.reduce(@unsafe_elements, nodes, &Floki.filter_out(&2, &1))
  end

  defp replace_live_only_content(nodes, context) do
    Floki.traverse_and_update(nodes, fn
      {tag, _attrs, _children} when tag in @live_only_elements ->
        unavailable("this embedded content", context)

      {"ac:structured-macro", attrs, _children} = node ->
        case List.keyfind(attrs, "ac:name", 0) do
          {"ac:name", name} -> unavailable(macro_label(name), context)
          nil -> node
        end

      node ->
        node
    end)
  end

  defp macro_label(name), do: Map.get(@macro_labels, name, "the #{name} macro")

  # The link is written as a plain Confluence URL so the usual anchor rewriting
  # turns it into an absolute link back to the original page.
  defp unavailable(what, context) do
    {"div", [{"class", "mirror-unavailable"}],
     [
       {"p", [],
        [
          {"strong", [], ["Sorry, this content cannot be shown in the static mirror."]},
          " ",
          what |> String.capitalize(),
          " is rendered live by Confluence."
        ]},
       {"p", [], ["Open the ", original_link(context), " to see it there."]}
     ]}
  end

  defp original_link(%{page: %{external_url: url}}) when is_binary(url) and url != "" do
    {"a", [{"href", url}], ["original page"]}
  end

  defp original_link(_context), do: "original Confluence page"

  defp mark_spaces(html) do
    Regex.replace(@inter_tag_space, html, fn run ->
      "\uE000" <> Base.url_encode64(run, padding: false) <> "\uE001"
    end)
  end

  defp restore_spaces(html) do
    Regex.replace(@space_marker, html, fn _, encoded ->
      Base.url_decode64!(encoded, padding: false)
    end)
  end

  defp traverse_and_rewrite(nodes, context) do
    Floki.traverse_and_update(nodes, fn
      {"a", attrs, children} ->
        {"a", rewrite_anchor(attrs, children, context), children}

      {"img", attrs, children} ->
        {"img", rewrite_image(attrs, context), children}

      {"div", attrs, children} ->
        if has_class?(attrs, "expand-container") do
          expand_to_details(children)
        else
          {"div", sanitise_attributes(attrs), children}
        end

      {tag, attrs, children} ->
        {tag, sanitise_attributes(attrs), children}

      other ->
        other
    end)
  end

  # Confluence's expand macro is a div pair toggled by JavaScript. A mirror has
  # no editing JavaScript, so it becomes the native, accessible equivalent: a
  # closed <details> with the original control text as <summary>.
  defp expand_to_details(children) do
    control = find_child(children, "expand-control")
    content = find_child(children, "expand-content")

    if control && content do
      {"details", [{"class", "expand-container"}],
       [
         {"summary", [{"class", "expand-control"}], reject_icon(control)},
         {"div", [{"class", "expand-content"}], content}
       ]}
    else
      {"div", [{"class", "expand-container"}], children}
    end
  end

  defp find_child(children, class) do
    Enum.find_value(children, fn
      {"div", attrs, kids} -> if has_class?(attrs, class), do: kids
      _ -> nil
    end)
  end

  defp reject_icon(children) do
    Enum.reject(children, fn
      {"span", attrs, _kids} -> has_class?(attrs, "expand-control-icon")
      _ -> false
    end)
  end

  defp has_class?(attrs, class) do
    case List.keyfind(attrs, "class", 0) do
      {"class", value} -> class in String.split(value)
      nil -> false
    end
  end

  defp rewrite_anchor(attrs, children, context) do
    case Floki.attribute({"a", attrs, children}, "href") do
      [href | _] ->
        case classify_href(href, context) do
          {:internal, path} -> attrs |> put_attribute("href", path) |> put_rel(context)
          {:attachment, path} -> put_attribute(attrs, "href", path)
          {:external, url} -> attrs |> put_attribute("href", url) |> put_rel(context)
        end

      [] ->
        attrs
    end
  end

  defp rewrite_image(attrs, context) do
    attrs =
      case Floki.attribute({"img", attrs, []}, "src") do
        [src | _] ->
          case classify_href(src, context) do
            {:attachment, path} -> put_attribute(attrs, "src", path)
            {:internal, path} -> put_attribute(attrs, "src", path)
            {:external, url} -> put_attribute(attrs, "src", url)
          end

        [] ->
          attrs
      end

    attrs
    |> put_default("alt", "")
    |> put_default("loading", "lazy")
    |> sanitise_attributes()
  end

  defp put_rel(attrs, context) do
    case List.keyfind(attrs, "href", 0) do
      {"href", href} ->
        if absolute_url?(href) and not same_origin?(href, context.base_url) do
          attrs
          |> put_default("rel", "noopener noreferrer")
          |> put_default("target", "_blank")
        else
          attrs
        end

      nil ->
        attrs
    end
  end

  defp put_default(attrs, name, value) do
    if List.keymember?(attrs, name, 0), do: attrs, else: [{name, value} | attrs]
  end

  defp put_attribute(attrs, name, value) do
    [{name, value} | List.keydelete(attrs, name, 0)]
  end

  @doc false
  # Classifies a raw href into what the mirror should do with it:
  #
  # * `{:internal, path}`   – mirrored page or in-page anchor
  # * `{:attachment, path}` – mirrored attachment, rewritten to the blob route
  # * `{:external, url}`    – absolute URL back to the original / the web
  def classify_href(href, context) do
    href = String.trim(href || "")

    cond do
      href == "" ->
        {:external, href}

      String.starts_with?(href, "#") ->
        {:internal, href}

      unsafe_scheme?(href) ->
        {:external, "#"}

      page_id = page_id_from_path(href) ->
        page_link(page_id, context)

      attachment = attachment_from_path(href) ->
        attachment_link(attachment, href, context)

      true ->
        {:external, absolutise(href, context)}
    end
  end

  defp page_link(confluence_id, context) do
    case get_in(context, [:pages, confluence_id]) do
      %{space_key: space_key, confluence_id: id, slug: slug} ->
        {:internal, URLs.page_path(space_key, id, slug)}

      nil ->
        {:external, absolutise("/pages/viewpage.action?pageId=#{confluence_id}", context)}
    end
  end

  defp attachment_link({page_id, filename}, href, context) do
    case get_in(context, [:attachments, filename]) do
      %{confluence_id: attachment_id, page_confluence_id: ^page_id, space_key: space_key} ->
        {:attachment, URLs.attachment_path(space_key, page_id, attachment_id, filename)}

      _ ->
        {:external, absolutise(href, context)}
    end
  end

  @doc false
  def page_id_from_path(href) do
    patterns = [
      ~r{/pages/(\d+)(?:/|\?|$|#)},
      ~r{[?&]pageId=(\d+)}
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, href) do
        [_, id | _] -> String.to_integer(id)
        _ -> nil
      end
    end)
  end

  @doc false
  def attachment_from_path(href) do
    patterns = [
      ~r{/download/(?:thumbnails|attachments)/(\d+)/([^?#]+)},
      ~r{/download/attachments/(\d+)/([^?#]+)}
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, href) do
        [_, page_id, filename | _] -> {String.to_integer(page_id), URI.decode(filename)}
        _ -> nil
      end
    end)
  end

  defp unsafe_scheme?(href) do
    downcased = href |> to_string() |> String.trim() |> String.downcase()

    String.starts_with?(downcased, "javascript:") or
      String.starts_with?(downcased, "vbscript:") or
      String.starts_with?(downcased, "data:text/html")
  end

  @doc false
  def absolutise(href, %{base_url: base_url}) do
    cond do
      href == "" -> href
      String.starts_with?(href, "#") -> href
      absolute_url?(href) -> href
      is_nil(base_url) -> href
      String.starts_with?(href, "/") -> base_url |> origin() |> Kernel.<>(href)
      true -> base_url |> String.trim_trailing("/") |> Kernel.<>("/") |> Kernel.<>(href)
    end
  end

  defp origin(base_url) do
    uri = URI.parse(base_url)
    %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string() |> String.trim_trailing("/")
  end

  defp absolute_url?(href), do: Regex.match?(~r{^[a-zA-Z][a-zA-Z0-9+.-]*:}, href)

  defp same_origin?(href, base_url) do
    with %URI{host: host} when is_binary(host) <- URI.parse(href),
         %URI{host: base_host} when is_binary(base_host) <- URI.parse(base_url || "") do
      String.downcase(host) == String.downcase(base_host)
    else
      _ -> false
    end
  end

  defp link_record(anchor, context) do
    href = anchor |> Floki.attribute("href") |> List.first() || ""
    label = anchor |> Floki.text() |> String.trim() |> String.slice(0, 200)

    case classify_href(href, context) do
      {:internal, path} ->
        %{
          href: path,
          kind: "internal",
          target_confluence_id: page_id_from_path(href),
          label: label
        }

      {:attachment, path} ->
        %{href: path, kind: "attachment", target_confluence_id: nil, label: label}

      {:external, url} ->
        %{
          href: url,
          kind: "external",
          target_confluence_id: page_id_from_path(href),
          label: label
        }
    end
  end

  defp sanitise_attributes(attrs) do
    attrs
    |> Enum.reject(fn {name, _value} -> String.starts_with?(String.downcase(name), "on") end)
    |> Enum.map(fn {name, value} -> {name, sanitise_attribute(name, value)} end)
  end

  defp sanitise_attribute(name, value) when name in @url_attributes do
    if unsafe_scheme?(value), do: "#", else: value
  end

  defp sanitise_attribute(_name, value), do: value
end
