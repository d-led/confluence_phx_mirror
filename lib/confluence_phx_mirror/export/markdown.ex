defmodule ConfluencePhxMirror.Export.Markdown do
  @moduledoc """
  Converts a mirrored `export_view` body to Markdown.

  This is an export, not a renderer: it targets the structures Confluence puts
  in a page — headings, lists, tables, code blocks, panels, expands, links and
  images. Anything it does not understand is kept as its text, so nothing a
  reader can see disappears from the export.

  `ctx` carries the relative-path maps so links between exported pages and
  attachment links stay inside the archive:

    * `:page_files` – `%{confluence_id => "Space/Page/Page.md"}`
    * `:current_folder` – folder of the page being converted
    * `:attachments` – `%{"/attachments/..." => "attachments/file.ext"}`
  """

  @doc "Converts an HTML fragment to Markdown."
  @spec from_html(String.t() | nil, map()) :: String.t()
  def from_html(html, ctx \\ %{})

  def from_html(nil, _ctx), do: ""
  def from_html("", _ctx), do: ""

  def from_html(html, ctx) when is_binary(html) do
    html
    |> Floki.parse_fragment!()
    |> blocks(ctx)
    |> String.trim()
    |> Kernel.<>("\n")
  end

  # ---------------------------------------------------------------------------
  # Blocks
  # ---------------------------------------------------------------------------

  defp blocks(nodes, ctx), do: Enum.map_join(nodes, "", &block(&1, ctx))

  defp block({"h" <> level, _attrs, kids}, ctx) when level in ~w(1 2 3 4 5 6) do
    "\n" <> String.duplicate("#", String.to_integer(level)) <> " " <> inline(kids, ctx) <> "\n\n"
  end

  defp block({"p", _attrs, kids}, ctx), do: inline(kids, ctx) <> "\n\n"

  defp block({"ul", _, items}, ctx), do: list(items, ctx, "- ")
  defp block({"ol", _, items}, ctx), do: list(items, ctx, "1. ")

  defp block({"pre", attrs, kids}, _ctx), do: code_block(attrs, kids)
  defp block({"blockquote", _, kids}, ctx), do: quote_block(blocks(kids, ctx))
  defp block({"table", _, _} = node, ctx), do: table(node, ctx)
  defp block({"hr", _, _}, _ctx), do: "\n---\n\n"
  defp block({"br", _, _}, _ctx), do: "  \n"

  defp block({"details", _, kids}, ctx), do: details(kids, ctx)

  defp block({"img", attrs, _}, ctx), do: image(attrs, ctx) <> "\n\n"

  defp block({tag, _, kids}, ctx) when tag in ~w(div section article header footer main) do
    blocks(kids, ctx)
  end

  defp block({tag, _, kids}, ctx) when tag in ~w(span strong b em i code a u s del) do
    inline([{tag, [], kids}], ctx)
  end

  defp block(text, _ctx) when is_binary(text), do: escape(String.trim(text))
  defp block(_node, _ctx), do: ""

  # ---------------------------------------------------------------------------
  # Lists
  # ---------------------------------------------------------------------------

  defp list(items, ctx, marker) do
    rendered =
      items
      |> Enum.filter(&match?({"li", _, _}, &1))
      |> Enum.map_join("\n", fn {"li", _, kids} ->
        {nested, rest} = Enum.split_with(kids, &nested_list?/1)

        text =
          rest
          |> inline(ctx)
          |> String.trim()

        indent(marker <> text, nested, ctx)
      end)

    "\n" <> rendered <> "\n\n"
  end

  defp nested_list?({tag, _, _}) when tag in ["ul", "ol"], do: true
  defp nested_list?(_node), do: false

  defp indent(line, [], _ctx), do: line

  defp indent(line, nested, ctx) do
    nested_text =
      nested
      |> Enum.map_join("", fn node ->
        node
        |> block(ctx)
        |> String.trim_trailing()
        |> then(&("\n" <> &1))
      end)
      |> prefix_lines("  ")

    line <> nested_text
  end

  defp prefix_lines(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

  defp quote_block(text) do
    text
    |> String.trim_trailing()
    |> prefix_lines("> ")
    |> Kernel.<>("\n\n")
  end

  # ---------------------------------------------------------------------------
  # Code
  # ---------------------------------------------------------------------------

  defp code_block(attrs, kids) do
    source = kids |> Floki.text() |> String.trim_trailing()
    fence = if String.contains?(source, "```"), do: "````", else: "```"
    "\n" <> fence <> language(attrs) <> "\n" <> source <> "\n" <> fence <> "\n\n"
  end

  defp language(attrs) do
    params = attr(attrs, "data-syntaxhighlighter-params") || ""
    class = attr(attrs, "class") || ""

    case Regex.run(~r/brush:\s*([^;]+)/i, params) do
      [_, brush] ->
        brush |> String.trim() |> String.downcase()

      nil ->
        case Regex.run(~r/language-([\w+-]+)/, class) do
          [_, language] -> language
          nil -> ""
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Tables
  # ---------------------------------------------------------------------------

  defp table({"table", _, _} = node, ctx) do
    rows =
      node
      |> Floki.find("tr")
      |> Enum.map(&table_row(&1, ctx))
      |> Enum.reject(&(&1 == []))

    case rows do
      [] ->
        ""

      [header | body] ->
        "\n"
        |> Kernel.<>(row(header))
        |> Kernel.<>(separator(length(header)))
        |> Kernel.<>(Enum.map_join(body, "", &row/1))
        |> Kernel.<>("\n")
    end
  end

  defp table_row({"tr", _, cells}, ctx) do
    cells
    |> Enum.filter(&match?({tag, _, _} when tag in ["th", "td"], &1))
    |> Enum.map(fn {_tag, _attrs, kids} ->
      kids |> inline(ctx) |> String.trim() |> String.replace("|", "\\|")
    end)
  end

  defp table_row(_other, _ctx), do: []

  defp row(cells), do: "| " <> Enum.join(cells, " | ") <> " |\n"
  defp separator(count), do: "| " <> Enum.map_join(1..count, " | ", fn _ -> "---" end) <> " |\n"

  # ---------------------------------------------------------------------------
  # Expands and images
  # ---------------------------------------------------------------------------

  defp details(kids, ctx) do
    summary =
      case Floki.find(kids, "summary") do
        [node | _] -> node |> Floki.text() |> String.trim()
        [] -> "Details"
      end

    body =
      kids
      |> Enum.reject(&match?({"summary", _, _}, &1))
      |> blocks(ctx)
      |> String.trim()

    "\n**" <> escape(summary) <> "**\n\n" <> body <> "\n\n"
  end

  defp image(attrs, ctx) do
    src = resolve(attr(attrs, "src"), ctx)
    alt = attr(attrs, "alt") || ""
    "![" <> escape(alt) <> "](" <> src <> ")"
  end

  # ---------------------------------------------------------------------------
  # Inline
  # ---------------------------------------------------------------------------

  defp inline(nodes, ctx), do: nodes |> inline_nodes(ctx) |> String.trim()

  defp inline_nodes(nodes, ctx) when is_list(nodes),
    do: Enum.map_join(nodes, "", &inline_node(&1, ctx))

  defp inline_node(text, _ctx) when is_binary(text), do: collapse(text)
  defp inline_node({"strong", _, kids}, ctx), do: "**" <> inline_nodes(kids, ctx) <> "**"
  defp inline_node({"b", _, kids}, ctx), do: "**" <> inline_nodes(kids, ctx) <> "**"
  defp inline_node({"em", _, kids}, ctx), do: "*" <> inline_nodes(kids, ctx) <> "*"
  defp inline_node({"i", _, kids}, ctx), do: "*" <> inline_nodes(kids, ctx) <> "*"
  defp inline_node({"code", _, kids}, _ctx), do: "`" <> Floki.text(kids) <> "`"
  defp inline_node({"br", _, _}, _ctx), do: "  \n"
  defp inline_node({"img", attrs, _}, ctx), do: image(attrs, ctx)

  defp inline_node({"a", attrs, kids}, ctx) do
    href = resolve(attr(attrs, "href"), ctx)
    label = kids |> inline_nodes(ctx) |> String.trim()

    case {label, href} do
      {"", _} -> ""
      {label, ""} -> label
      {label, href} -> "[" <> label <> "](" <> href <> ")"
    end
  end

  defp inline_node({_tag, _attrs, kids}, ctx), do: inline_nodes(kids, ctx)
  defp inline_node(_node, _ctx), do: ""

  # Collapses whitespace the way HTML rendering does, but keeps one space
  # between inline siblings.
  defp collapse(text) do
    text
    |> String.replace(~r/[ \t\r\n]+/u, " ")
    |> escape()
  end

  defp escape(text), do: String.replace(text, ~r/([\\`*_\[\]])/u, "\\\\\\1")

  # ---------------------------------------------------------------------------
  # Link resolution
  # ---------------------------------------------------------------------------

  defp resolve(nil, _ctx), do: ""
  defp resolve("", _ctx), do: ""

  defp resolve(href, ctx) do
    cond do
      attachment = attachment_path(href, ctx) -> attachment
      page = page_path(href, ctx) -> page
      true -> href
    end
  end

  defp attachment_path(href, ctx) do
    attachments = Map.get(ctx, :attachments, %{})

    case Map.get(attachments, href) do
      nil ->
        foreign_attachment(href, ctx)

      path ->
        path
    end
  end

  # A mirror attachment path the archive does not carry is another page's file.
  # The page body points at the mirror (the reader opens it there), but a file in
  # a zip has no server behind it, so the export sends the reader back to where
  # the bytes came from instead of to a path that is not in the archive.
  defp foreign_attachment("/attachments/" <> _rest = href, ctx) do
    with [_, owner, name] <- Regex.run(~r{^/attachments/[^/]+/(\d+)/[^/]+/(.+)$}, href),
         origin when is_binary(origin) and origin != "" <- Map.get(ctx, :source_url) do
      origin |> site_origin() |> Kernel.<>("/wiki/download/attachments/#{owner}/#{name}")
    else
      _ -> Path.basename(href)
    end
  end

  defp foreign_attachment(href, _ctx) do
    if String.starts_with?(href, "/attachments/"), do: Path.basename(href)
  end

  defp site_origin(url) do
    uri = URI.parse(url)
    %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string() |> String.trim_trailing("/")
  end

  defp page_path(href, ctx) do
    case Regex.run(~r{/(?:pages|blog)/(\d+)}, href) do
      [_, id] ->
        files = Map.get(ctx, :page_files, %{})
        folder = Map.get(ctx, :current_folder, "")

        case Map.get(files, String.to_integer(id)) do
          nil -> nil
          target -> relative(target, folder)
        end

      nil ->
        nil
    end
  end

  defp relative(target, folder) do
    Path.relative_to(target, folder || ".")
  end

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
