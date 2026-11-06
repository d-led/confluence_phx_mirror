defmodule Mix.Tasks.Mirror.Links do
  @shortdoc "Counts how many stored links still name the site, and how many of those the mirror could have honoured"

  @moduledoc """
  Whether the stored bodies link inside the mirror, counted statically.

      mix mirror.links

  It reads every stored body and asks, of each anchor that still names the site,
  whether the mirror **holds** what it names. Holding the target and still
  pointing at the site is a **miss**. Anchors naming something the mirror does
  not have — a page nobody mirrored, a person it has never seen, a write action
  it does not offer — are counted apart, so a miss cannot hide among them.

  A miss in a body drawn by an older `Sync.Renderer.revision/0` is work the next
  sync will do; a miss at the current revision is a defect. The report separates
  the two, and prints the rate over the anchors that lead inside.

  Nothing here needs the network: it reads what is stored.
  """

  use Mix.Task

  import Ecto.Query

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.{Mirror, Repo}
  alias ConfluencePhxMirror.Sync.Renderer

  @batch 500

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    host = site_host()

    if host == "" do
      Mix.raise("no site is configured (CM_CONFLUENCE_SITE), so there is nothing to count")
    end

    {tally, bodies} =
      tally(%{anchors: 0, pages: [], spaces: [], people: [], other: []}, host, 0, 0)

    report(tally, bodies)
  end

  defp tally(acc, host, after_id, bodies) do
    batch =
      Repo.all(
        from(p in Mirror.Page,
          where: p.id > ^after_id and not is_nil(p.body_export),
          order_by: p.id,
          limit: @batch,
          select: {p.id, p.render_revision, p.external_url, p.body_export}
        )
      )

    case batch do
      [] ->
        {acc, bodies}

      rows ->
        acc = Enum.reduce(rows, acc, &tally_body(&2, &1, host))
        tally(acc, host, rows |> List.last() |> elem(0), bodies + length(rows))
    end
  end

  defp tally_body(acc, {_id, revision, source, body}, host) do
    anchors = anchors(body)

    Enum.reduce(anchors, Map.update!(acc, :anchors, &(&1 + length(anchors))), fn href, acc ->
      if href == source, do: acc, else: tally_anchor(acc, href, host, revision)
    end)
  end

  defp anchors(body) do
    ~r/href="([^"]+)"/
    |> Regex.scan(body)
    |> Enum.map(fn [_all, href] -> href end)
  end

  defp tally_anchor(acc, href, host, revision) do
    if site_address?(href, host), do: count_target(acc, target(href), revision), else: acc
  end

  defp count_target(acc, {:page, id}, revision),
    do: Map.update!(acc, :pages, &[{id, revision} | &1])

  defp count_target(acc, {:space, key}, revision),
    do: Map.update!(acc, :spaces, &[{key, revision} | &1])

  defp count_target(acc, {:person, account}, revision),
    do: Map.update!(acc, :people, &[{account, revision} | &1])

  defp count_target(acc, :other, _revision), do: Map.update!(acc, :other, &[nil | &1])

  defp site_address?(href, host) do
    case URI.parse(href) do
      %URI{host: ^host} -> true
      _not_the_site -> false
    end
  end

  # The spellings the renderer answers, in its order: a person's space is a
  # `/display/~…` path, so it is asked before the plain `/display/KEY` one, and a
  # space path has to end at its key — otherwise a whiteboard inside a space reads
  # as the space itself.
  @targets [
    {~r/[?&]pageId=(\d+)/, :page},
    {~r{/pages/(\d+)}, :page},
    {~r{/(?:wiki/)?people/([^/?#]+)}, :person},
    {~r{/(?:wiki/)?display/~([^/?#]+)}, :person},
    {~r{/(?:wiki/)?(?:spaces|display)/([^/?#]+)(?:/overview)?/?$}, :space}
  ]

  defp target(href) do
    Enum.find_value(@targets, :other, fn {pattern, kind} ->
      case Regex.run(pattern, href) do
        [_all, value] -> {kind, value_of(kind, value)}
        nil -> nil
      end
    end)
  end

  defp value_of(:page, value), do: String.to_integer(value)
  defp value_of(_kind, value), do: URI.decode(value)

  defp report(tally, bodies) do
    held = %{
      pages: held_pages(tally.pages),
      spaces: held_spaces(tally.spaces),
      people: held_people(tally.people)
    }

    misses =
      miss(tally.pages, held.pages) ++
        miss(tally.spaces, held.spaces) ++ miss(tally.people, held.people)

    translatable = length(tally.pages) + length(tally.spaces) + length(tally.people)
    misses_count = length(misses)
    named = translatable + length(tally.other)
    rate = if tally.anchors == 0, do: 1.0, else: (tally.anchors - misses_count) / tally.anchors

    IO.puts("""
    pages in the mirror                #{total_pages()}
    pages with a stored body           #{bodies}
    anchors in those bodies            #{tally.anchors}
    anchors naming the site            #{named}
      what it names is held            #{misses_count}   <- a miss
      nothing a mirror can translate   #{named - misses_count}
    translation rate                   #{Float.round(rate * 100, 2)}%  (anchors that lead inside)
    """)

    if misses != [] do
      current = Renderer.revision()
      fresh = Enum.filter(misses, fn {_value, revision} -> revision >= current end)
      old = misses -- fresh

      IO.puts(
        "misses in bodies drawn by older revisions: #{length(old)}, revisions " <>
          inspect(revisions(old), charlists: :as_lists)
      )

      if fresh == [] do
        IO.puts("misses at revision #{current} — a defect: none")
      else
        IO.puts(
          "misses at revision #{current} — a defect: #{length(fresh)}, revisions " <>
            inspect(revisions(fresh), charlists: :as_lists)
        )
      end
    end
  end

  defp miss(entries, held) do
    Enum.filter(entries, fn {value, _revision} -> value in held end)
  end

  defp revisions(entries), do: entries |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

  defp held_pages(entries) do
    entries
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> count_in_batches(fn batch ->
      from(p in Mirror.Page,
        where: p.confluence_id in ^batch and is_nil(p.deleted_at),
        select: p.confluence_id
      )
    end)
  end

  defp held_spaces(entries) do
    entries
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> count_in_batches(fn batch ->
      from(s in Mirror.Space, where: s.key in ^batch, select: s.key)
    end)
  end

  defp held_people(entries) do
    entries
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> count_in_batches(fn batch ->
      from(p in Mirror.Person, where: p.account_id in ^batch, select: p.account_id)
    end)
  end

  defp count_in_batches(values, query) do
    values
    |> Enum.chunk_every(500)
    |> Enum.flat_map(&Repo.all(query.(&1)))
  end

  defp total_pages, do: Repo.one(from p in Mirror.Page, select: count(p.id))

  defp site_host do
    case Application.get_env(:confluence_phx_mirror, HttpSource, [])[:base_url] do
      nil -> ""
      base -> base |> URI.parse() |> Map.get(:host) |> to_string()
    end
  end
end
