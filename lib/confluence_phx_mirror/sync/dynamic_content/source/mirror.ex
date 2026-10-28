defmodule ConfluencePhxMirror.Sync.DynamicContent.Source.Mirror do
  @moduledoc """
  The content port over the mirror's own database.

  Each answer is narrowed to the pages a host page's readers may open before a
  renderer sees it, so the audience rule is applied once, here, instead of in
  every macro (`ConfluencePhxMirror.Authorization.readable_alongside/2`).
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Source

  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Page

  @impl true
  def pages_by_label(%Page{} = host, labels, opts) do
    labels
    |> Mirror.pages_for_labels(space_option(opts, host))
    |> visible_to(host)
  end

  @impl true
  def property_report(%Page{} = host, space, columns) do
    report = Mirror.property_report(space_id(space, host), columns)

    %{report | rows: narrow(report.rows, & &1.page, host)}
  end

  @impl true
  def children(%Page{} = host, %Page{} = page, opts) do
    page
    |> Mirror.children(opts)
    |> visible_to(host)
  end

  # A marker may name a space; one that does not lists every space, which is how
  # Confluence's own macro behaves. A key the mirror does not import is the
  # host's space, so the marker still renders something.
  defp space_option(opts, host) do
    case Keyword.get(opts, :space) do
      key when key in [nil, ""] -> Keyword.delete(opts, :space)
      key -> opts |> Keyword.delete(:space) |> Keyword.put(:space_id, space_id(key, host))
    end
  end

  # The column, not the association: a page handed to a macro while a run is
  # writing it carries no preloaded space, and its own `space_id` is exactly the
  # fallback the marker wants.
  defp space_id(key, host) when key in [nil, ""], do: host.space_id

  defp space_id(key, host) do
    case Mirror.find_space(key) do
      {:ok, found} -> found.id
      {:error, :not_found} -> host.space_id
    end
  end

  defp visible_to(pages, host), do: narrow(pages, & &1, host)

  defp narrow(rows, page_of, host) do
    allowed =
      host
      |> Authorization.readable_alongside(Enum.map(rows, page_of))
      |> MapSet.new(& &1.id)

    Enum.filter(rows, &MapSet.member?(allowed, page_of.(&1).id))
  end
end
