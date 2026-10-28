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
  alias ConfluencePhxMirror.Mirror.{Page, Search}

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

  @impl true
  def descendants(%Page{} = host, %Page{} = page, opts) do
    %{items: items} = Mirror.descendants(page, opts)

    visible_to(items, host)
  end

  @impl true
  def page_by_title(%Page{} = host, title) do
    with {:ok, space} <- space_of(host),
         {:ok, page} <- find_in_space(space.key, title),
         true <- readable?(host, page) do
      {:ok, page}
    else
      _ -> :error
    end
  end

  # Confluence writes a page in another space as `KEY/Page Title`. A title that
  # merely contains a slash — "A/B testing" — is a title, so the prefix only
  # counts when it is shaped like a key *and* names a space this mirror holds.
  defp find_in_space(host_key, title) do
    with [prefix, rest] when rest != "" <- String.split(title, "/", parts: 2),
         true <- String.match?(prefix, ~r/^[A-Z][A-Z0-9_]*$/),
         {:ok, _space} <- Mirror.find_space(prefix) do
      Mirror.find_page_by_title(prefix, rest)
    else
      _ -> Mirror.find_page_by_title(host_key, title)
    end
  end

  @impl true
  def search(%Page{} = host, cql) do
    with {:ok, results} <- Search.search(cql) do
      {:ok, results |> Enum.map(& &1.page) |> visible_to(host)}
    end
  end

  @impl true
  def attachments(%Page{} = page), do: Mirror.attachments(page)

  # A contributor list is about names and counts, not about bodies: the scan is
  # one light row per page, and the audience rule decides which of those rows may
  # be counted. Past the cap the answer is `:too_large` — a count that quietly
  # stopped halfway is worse than a sentence saying the space is too big to count.
  @contributor_scan 5_000

  @impl true
  def contributors(%Page{} = host, space, opts) do
    rows = Mirror.space_authors(space_id(space, host), limit: @contributor_scan + 1)

    if length(rows) > @contributor_scan do
      {:error, :too_large}
    else
      {:ok, rows |> visible_to(host) |> ranked(opts)}
    end
  end

  defp ranked(rows, opts) do
    rows
    |> Enum.group_by(&{&1.name, &1.account_id})
    |> Enum.map(fn {{name, account_id}, pages} ->
      %{name: name, account_id: account_id, pages: length(pages)}
    end)
    |> Enum.sort_by(&{-&1.pages, &1.name})
    |> Enum.take(Keyword.get(opts, :limit, 10))
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
  # writing it carries no preloaded space, so the trail starts at `space_id` and
  # walks to the row only when it needs the key.
  defp space_id(key, host) when key in [nil, ""], do: host.space_id

  defp space_id(key, host) do
    case Mirror.find_space(key) do
      {:ok, found} -> found.id
      {:error, :not_found} -> host.space_id
    end
  end

  defp space_of(%Page{space: %{key: _} = space}), do: {:ok, space}
  defp space_of(%Page{space_id: id}), do: Mirror.find_space_by_id(id)

  defp visible_to(pages, host), do: narrow(pages, & &1, host)

  defp readable?(host, page), do: Authorization.readable_alongside(host, [page]) != []

  defp narrow(rows, page_of, host) do
    allowed =
      host
      |> Authorization.readable_alongside(Enum.map(rows, page_of))
      |> MapSet.new(& &1.id)

    Enum.filter(rows, &MapSet.member?(allowed, page_of.(&1).id))
  end
end
