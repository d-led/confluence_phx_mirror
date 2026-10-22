defmodule ConfluencePhxMirror.Sync.DynamicContent do
  @moduledoc """
  Resolves Confluence's browser-only macros into static HTML at sync time.

  Confluence renders macros such as *Content by Label* and *Page Properties
  Report* in the browser, so `export_view` only carries a placeholder. A static
  mirror cannot run that JavaScript, so it resolves these macros against its own
  database and bakes the result into the page body. The output is ordinary HTML:
  it is searchable, printable and needs no client-side code.

  A placeholder is a `div` carrying `class="mirror-macro"` and
  `data-macro`:

      <div class="mirror-macro" data-macro="content-by-label"
           data-labels="runbook,incident" data-match="all" data-limit="10"></div>

      <div class="mirror-macro" data-macro="page-properties-report"
           data-space="ENG" data-columns="owner,status"></div>

  The marker element is kept and its children replaced, so expanding an already
  expanded body is safe — that is how `Sync` refreshes dependents after a page
  changes, without a dependency graph or recursion.
  """

  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs

  @doc """
  Expands every dynamic macro marker in `html` for the space context.

  The context carries the page the macros appear on, because a listing baked in
  at sync time is shown to every reader of that page and may only name pages
  they may open themselves (see `Authorization.readable_alongside/2`).
  """
  @spec expand(String.t(), %{space: Mirror.Space.t(), page: Mirror.Page.t()}) :: String.t()
  def expand(html, %{space: space, page: page}) when is_binary(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.traverse_and_update(fn
      {"div", attrs, _children} = node ->
        if marker?(attrs), do: {"div", attrs, resolve(attrs, space, page)}, else: node

      node ->
        node
    end)
    |> Floki.raw_html()
  end

  def expand(html, _context), do: html

  defp marker?(attrs), do: "mirror-macro" in classes(attrs)

  defp resolve(attrs, space, host) do
    case attr(attrs, "data-macro") do
      "content-by-label" -> content_by_label(attrs, space, host)
      "page-properties-report" -> properties_report(attrs, space, host)
      macro -> [notice("Dynamic macro #{inspect(macro)} is not supported by the mirror.")]
    end
  end

  # ---------------------------------------------------------------------------
  # content-by-label
  # ---------------------------------------------------------------------------

  defp content_by_label(attrs, space, host) do
    labels = split(attr(attrs, "data-labels"))
    match = if attr(attrs, "data-match") == "any", do: :any, else: :all

    candidates =
      Mirror.pages_for_labels(labels,
        match: match,
        limit: positive_int(attr(attrs, "data-limit"), 10),
        space_id: space_id(attr(attrs, "data-space"), space)
      )

    case Authorization.readable_alongside(host, candidates) do
      [] ->
        [empty("No content carries these labels yet.")]

      pages ->
        [
          heading("Content by label: #{Enum.join(labels, ", ")}"),
          {"ul", [{"class", "mirror-dynamic-list"}], Enum.map(pages, &page_item/1)}
        ]
    end
  end

  defp page_item(page) do
    {"li", [],
     [
       {"a",
        [{"href", URLs.content_path(page.space.key, page)}, {"class", "mirror-dynamic-link"}],
        [page.title]},
       {"span", [{"class", "mirror-dynamic-meta"}], [" · #{page.space.key} · #{updated(page)}"]}
     ]}
  end

  # ---------------------------------------------------------------------------
  # page-properties-report
  # ---------------------------------------------------------------------------

  defp properties_report(attrs, space, host) do
    report_space = report_space(attr(attrs, "data-space"), space)
    report = Mirror.property_report(report_space.id, split(attr(attrs, "data-columns")))
    rows = listable_rows(report.rows, host)

    case rows do
      [] ->
        [empty("No page in this space declares properties yet.")]

      rows ->
        [
          heading("Page properties report"),
          {"table", [{"class", "confluenceTable mirror-dynamic-report"}],
           [
             {"thead", [], [{"tr", [], Enum.map(["Page" | report.columns], &{"th", [], [&1]})}]},
             {"tbody", [], Enum.map(rows, &report_row(&1, report.columns))}
           ]}
        ]
    end
  end

  defp listable_rows(rows, host) do
    listable =
      host
      |> Authorization.readable_alongside(Enum.map(rows, & &1.page))
      |> MapSet.new(& &1.id)

    Enum.filter(rows, &MapSet.member?(listable, &1.page.id))
  end

  defp report_row(%{page: page, values: values}, columns) do
    cells =
      Enum.map(columns, fn column ->
        {"td", [], [Map.get(values, column) || "—"]}
      end)

    {"tr", [],
     [
       {"td", [],
        [
          {"a",
           [{"href", URLs.content_path(page.space.key, page)}, {"class", "mirror-dynamic-link"}],
           [page.title]}
        ]}
       | cells
     ]}
  end

  # ---------------------------------------------------------------------------
  # Nodes and attributes
  # ---------------------------------------------------------------------------

  defp heading(text), do: {"p", [{"class", "mirror-dynamic-heading"}], [text]}
  defp empty(text), do: {"p", [{"class", "mirror-dynamic-empty"}], [text]}
  defp notice(text), do: {"p", [{"class", "mirror-dynamic-notice"}], [text]}

  defp updated(%{external_updated_at: nil}), do: "unknown date"

  defp updated(%{external_updated_at: at}),
    do: "updated " <> Calendar.strftime(at, "%d %b %Y")

  defp space_id(nil, _space), do: nil
  defp space_id("", _space), do: nil

  defp space_id(key, space) do
    case Mirror.find_space(key) do
      {:ok, found} -> found.id
      {:error, :not_found} -> space.id
    end
  end

  defp report_space(nil, space), do: space
  defp report_space("", space), do: space

  defp report_space(key, space) do
    case Mirror.find_space(key) do
      {:ok, found} -> found
      {:error, :not_found} -> space
    end
  end

  defp positive_int(nil, default), do: default

  defp positive_int(value, default) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> min(number, 50)
      _ -> default
    end
  end

  defp split(nil), do: []

  defp split(value) do
    value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp classes(attrs) do
    attrs
    |> attr("class")
    |> to_string()
    |> String.split(" ", trim: true)
  end

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
