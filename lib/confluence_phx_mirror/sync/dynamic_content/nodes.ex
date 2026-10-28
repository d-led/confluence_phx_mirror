defmodule ConfluencePhxMirror.Sync.DynamicContent.Nodes do
  @moduledoc """
  The HTML vocabulary macros render with.

  One place for the markup and the classes the stylesheet knows, so a macro that
  is written next year looks like the ones written today without copying a
  `div`. Everything here is a Floki node; the expander serialises the lot.
  """

  alias ConfluencePhxMirror.Mirror.URLs

  @doc "What a macro is about — a line above the listing."
  def heading(text), do: {"p", [{"class", "mirror-dynamic-heading"}], [text]}

  @doc "The macro has nothing to show, and says so."
  def empty(text), do: {"p", [{"class", "mirror-dynamic-empty"}], [text]}

  @doc "The macro cannot be drawn faithfully, and says why."
  def notice(text), do: {"p", [{"class", "mirror-dynamic-notice"}], [text]}

  @doc "A list of pages: title, space and when it was last updated."
  def page_list(pages),
    do: {"ul", [{"class", "mirror-dynamic-list"}], Enum.map(pages, &page_item/1)}

  @doc "One listed page, linked through the reader route."
  def page_item(page) do
    {"li", [],
     [
       link(page),
       {"span", [{"class", "mirror-dynamic-meta"}],
        [" · #{page.space.key} · updated #{updated(page)}"]}
     ]}
  end

  @doc "A page's title, linked through the reader route."
  def link(page) do
    {"a", [{"href", URLs.content_path(page.space.key, page)}, {"class", "mirror-dynamic-link"}],
     [
       page.title
     ]}
  end

  @doc """
  A table: the header labels, then one row per list of cells.

  Cells are node lists, so a table can hold a link or a plain word without the
  caller knowing how a cell is spelled.
  """
  def table(columns, rows) do
    {"table", [{"class", "confluenceTable mirror-dynamic-report"}],
     [
       {"thead", [], [{"tr", [], Enum.map(columns, &{"th", [], [&1]})}]},
       {"tbody", [], Enum.map(rows, &{"tr", [], Enum.map(&1, fn cells -> {"td", [], cells} end)})}
     ]}
  end

  @doc "A list of people: the name, and how much of the space it stands on."
  def person_list(people),
    do: {"ul", [{"class", "mirror-dynamic-list"}], Enum.map(people, &person_item/1)}

  defp person_item(%{name: name, pages: pages}) do
    {"li", [],
     [
       {"span", [], [name]},
       {"span", [{"class", "mirror-dynamic-meta"}], [" · " <> written(pages)]}
     ]}
  end

  defp written(1), do: "1 page"
  defp written(count), do: "#{count} pages"

  @doc """
  A page's files: name linked to the mirrored blob, type and size beside it.

  The space key is given rather than read off the page: a run draws a page it has
  not finished writing, and that page's space association is not loaded.
  """
  def file_list(space_key, page, files) do
    {"ul", [{"class", "mirror-files"}], Enum.map(files, &file_item(space_key, page, &1))}
  end

  defp file_item(space_key, page, file) do
    href = URLs.attachment_path(space_key, page.confluence_id, file.confluence_id, file.filename)

    {"li", [],
     [
       {"a", [{"href", href}, {"class", "mirror-dynamic-link"}], [file.filename]},
       {"span", [{"class", "mirror-dynamic-meta"}], [" · #{describe(file)}"]}
     ]}
  end

  defp describe(file) do
    [file.media_type, size(file.byte_size)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp size(nil), do: nil
  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes) when bytes < 1024 * 1024, do: "#{round(bytes / 1024)} KB"
  defp size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  @doc "When a page was last updated, as a listing says it: `01 Oct 2026`."
  def updated(%{external_updated_at: nil}), do: "unknown date"

  def updated(%{external_updated_at: at}), do: Calendar.strftime(at, "%d %b %Y")
end
