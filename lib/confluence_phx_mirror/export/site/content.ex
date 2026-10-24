defmodule ConfluencePhxMirror.Export.Site.Content do
  @moduledoc """
  The parts of a page that change when the mirror becomes a folder of files.

  A mirrored body already points where it should *inside the mirror*: a link to
  a page the sync knew is `/spaces/KEY/pages/ID/Title`, a link to a file is
  `/attachments/KEY/PAGE/ATTACHMENT/name`. An archive turns those into files,
  so every mirrored target is re-pointed at the relative `.html` or at the
  attachment's bytes.

  Confluence pages also link to each other by full address
  (`https://site.atlassian.net/wiki/pages/viewpage.action?pageId=42`), and a
  body written by hand does so even when the page is mirrored. Those are the
  mirror's own site, so they are re-pointed the same way — the archive is a
  copy of the site, not a different one.

  The rule the sync applied — a mirrored target stays inside, anything else
  goes back to Confluence — is applied one step further out: a page the archive
  does not carry (a restricted page in a reader's copy, another space's page in
  a one-space archive) links to Confluence instead of to a file that is not in
  the zip.

  It also adds the heading permalinks the reader screens add in JavaScript, so
  an exported page needs no script at all.
  """

  alias ConfluencePhxMirror.Export.Site

  @type context :: %{
          required(:prefix) => String.t(),
          required(:pages) => %{integer() => String.t()},
          required(:external) => ([integer()] -> %{integer() => String.t()}),
          optional(:origins) => [String.t()],
          optional(:external_attachment) => (integer(), String.t() -> String.t() | nil)
        }

  @headings ~w(h1 h2 h3 h4 h5 h6)
  @page_path ~r{^/spaces/([^/?#]+)/(?:pages|blog)/(\d+)}
  @viewpage "/pages/viewpage.action?pageId="

  @doc """
  The body HTML as it should appear in the archive.

  `:prefix` is the relative path back to the archive root, `:pages` maps the
  Confluence ids the archive carries to their file, `:origins` are the site's
  own addresses, and `:external` answers the links whose target is not one of
  them.
  """
  @spec rewrite(String.t() | nil, context()) :: String.t()
  def rewrite(nil, _context), do: ""
  def rewrite("", _context), do: ""

  def rewrite(html, context) when is_binary(html) do
    nodes =
      html
      |> mark_spaces()
      |> Floki.parse_fragment!()

    urls = external_urls(nodes, context)

    nodes
    |> Floki.traverse_and_update(&node(&1, context, urls))
    |> Floki.raw_html()
    |> restore_spaces()
  end

  # ---------------------------------------------------------------------------
  # Nodes
  # ---------------------------------------------------------------------------

  defp node({"a", attrs, children}, context, urls) do
    {"a", rewrite_attribute(attrs, "href", context, urls), children}
  end

  defp node({"img", attrs, children}, context, urls) do
    {"img", rewrite_attribute(attrs, "src", context, urls), children}
  end

  defp node({tag, attrs, children}, _context, _urls) when tag in @headings do
    case List.keyfind(attrs, "id", 0) do
      {"id", id} -> {tag, attrs, children ++ [anchor(id)]}
      nil -> {tag, attrs, children}
    end
  end

  defp node(other, _context, _urls), do: other

  defp anchor(id) do
    {"a",
     [
       {"class", "heading-anchor"},
       {"href", "#" <> id},
       {"aria-label", "Link to this heading"},
       {"title", "Link to this heading"}
     ], ["#"]}
  end

  defp rewrite_attribute(attrs, name, context, urls) do
    case List.keyfind(attrs, name, 0) do
      {^name, value} ->
        List.keyreplace(attrs, name, 0, {name, rewrite_href(value, context, urls)})

      nil ->
        attrs
    end
  end

  # ---------------------------------------------------------------------------
  # Hrefs
  # ---------------------------------------------------------------------------

  defp rewrite_href(nil, _context, _urls), do: nil
  defp rewrite_href("", _context, _urls), do: ""
  defp rewrite_href("#" <> _fragment = href, _context, _urls), do: href

  defp rewrite_href(href, context, urls) do
    case site_path(href, context) do
      nil -> href
      "/attachments/" <> rest -> attachment_href(rest, context, href)
      path -> page_href(path, context, urls, href)
    end
  end

  # A path on the mirror's own site, with the site's address stripped when the
  # body used the full URL. Nothing else is ours to rewrite.
  defp site_path("/spaces/" <> _rest = path, _context), do: path
  defp site_path("/pages/viewpage.action?" <> _rest = path, _context), do: path
  defp site_path("/attachments/" <> _rest = path, _context), do: path

  defp site_path(href, context) do
    Enum.find_value(Map.get(context, :origins, []), fn origin ->
      case String.replace_prefix(href, origin, "") do
        ^href -> nil
        "/" <> _rest = path -> site_path(path, context)
        _other -> nil
      end
    end)
  end

  defp page_href("/spaces/" <> _rest = path, context, urls, href) do
    case Regex.run(@page_path, path) do
      [_, _space_key, id] -> known_page(String.to_integer(id), context, urls, href)
      nil -> href
    end
  end

  defp page_href(@viewpage <> id, context, urls, href) do
    case Integer.parse(id) do
      {confluence_id, ""} -> known_page(confluence_id, context, urls, href)
      _not_a_page -> href
    end
  end

  defp page_href(_path, _context, _urls, href), do: href

  defp known_page(confluence_id, context, urls, href) do
    case Map.get(context.pages, confluence_id) do
      nil -> Map.get(urls, confluence_id, href)
      file -> context.prefix <> file
    end
  end

  defp attachment_href(rest, context, href) do
    with [space_key, page_id, attachment_id, filename] <- String.split(rest, "/", parts: 4),
         {page_id, ""} <- Integer.parse(page_id) do
      if Map.has_key?(context.pages, page_id) do
        context.prefix <>
          Site.attachment_path(space_key, page_id, attachment_id, filename_of(filename))
      else
        outside_attachment(context, page_id, href)
      end
    else
      _not_an_attachment -> href
    end
  end

  defp outside_attachment(context, page_id, href) do
    filename = href |> String.split("/") |> List.last() |> filename_of()

    case Map.get(context, :external_attachment) do
      nil -> href
      fun -> fun.(page_id, filename) || href
    end
  end

  defp filename_of(filename) do
    filename
    |> String.split(["?", "#"], parts: 2)
    |> hd()
    |> URI.decode()
  end

  # ---------------------------------------------------------------------------
  # Out-of-archive targets, resolved once per page
  # ---------------------------------------------------------------------------

  defp external_urls(nodes, context) do
    targets =
      nodes
      |> Floki.find("a[href]")
      |> Enum.flat_map(fn node -> Floki.attribute(node, "href") end)
      |> Enum.flat_map(&page_id(&1, context))
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(context.pages, &1))

    if targets == [], do: %{}, else: context.external.(targets)
  end

  defp page_id(href, context) do
    case site_path(href, context) do
      @viewpage <> id ->
        case Integer.parse(id) do
          {confluence_id, ""} -> [confluence_id]
          _not_a_page -> []
        end

      nil ->
        []

      path ->
        case Regex.run(@page_path, path) do
          [_, _space_key, id] -> [String.to_integer(id)]
          nil -> []
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Whitespace
  # ---------------------------------------------------------------------------

  # Floki's parser drops text runs that are only whitespace, but those runs are
  # the visible space between inline elements: two status lozenges would touch
  # and `<strong>` next to `<em>` would read "onetwo". The same trap, and the
  # same two markers, are in `ConfluencePhxMirror.Sync.Renderer`, where the
  # mirror's own HTML is produced.
  @inter_tag_space ~r/(?<=>)\s+(?=<)/u
  @space_marker ~r/\x{E000}([A-Za-z0-9_-]+)\x{E001}/u

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
end
