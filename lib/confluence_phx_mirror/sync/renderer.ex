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

  @unsafe_elements ~w(script iframe object embed applet form input button)
  @url_attributes ~w(href src action formaction poster)

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
      |> Floki.raw_html()

    %{html: rewritten, links: links, text: plain_text(rewritten)}
  end

  @doc "Plain text of rendered HTML, used for Postgres full-text search."
  def plain_text(html) when is_binary(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def plain_text(_), do: ""

  defp remove_unsafe_elements(nodes) do
    Enum.reduce(@unsafe_elements, nodes, &Floki.filter_out(&2, &1))
  end

  defp traverse_and_rewrite(nodes, context) do
    Floki.traverse_and_update(nodes, fn
      {"a", attrs, children} ->
        {"a", rewrite_anchor(attrs, children, context), children}

      {"img", attrs, children} ->
        {"img", rewrite_image(attrs, context), children}

      {tag, attrs, children} ->
        {tag, sanitise_attributes(attrs), children}

      other ->
        other
    end)
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
