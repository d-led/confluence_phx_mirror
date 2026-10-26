defmodule ConfluencePhxMirror.Sync.Reconcile do
  @moduledoc """
  Asks the site what it still lists, and records what the mirror holds that it
  does not — without reading a single page.

  A sync notices deletions only inside the spaces it lists, and only as a side
  effect of reading every page of them. That leaves the question this module
  answers: *of the pages we hold, which ones does the site not name any more?*
  It is asked deliberately, so an operator can review the answer before anything
  moves to the trash.

  ## What it costs

  Reading the site is the expensive part of a mirror, so the pass is built to ask
  as little as possible, and to say how much it asked (`:asked` in the report):

    1. **One request per space and content type** for a *count*. A space whose
       counts agree with the mirror's is done — no page is listed at all, which
       is every space on a healthy mirror.
    2. **An id-only listing** for a space whose counts disagree, or for a source
       that cannot count. This is paginated like any listing but carries no
       bodies, no comments and no attachments: it is the cheapest form of "name
       everything you have".
    3. **Nothing else.** No page is re-read, re-rendered or re-synced.

  ## What it does with the answer

  Pages the site names have their absence cleared; pages it does not name get
  `absent_since` (`Mirror.mark_absent/2`). Nothing is trashed here — a listing
  that leaves a page out can also be a permission the token lost, so the
  decision is a person's, taken from `/admin/upstream`.

  A listing that names nothing for a space marks nothing: an empty answer is far
  more likely to be a filtering or permission problem than a deleted space, and
  the same rule guards the sync (`Sync.reconcile_deletions/2`).
  """

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Space

  @typedoc """
  What the pass found and what it spent.

    * `:spaces` — live spaces in the mirror this pass looked at;
    * `:agreed` — spaces whose counts matched, so nothing was listed;
    * `:listed` — spaces whose pages were listed, and how many are now absent;
    * `:absent` — pages absent after the pass;
    * `:asked` — questions put to the source: one count or one listing per space.
      A count is two HTTP requests on Confluence (one per content type), and a
      listing is one per page of results, so this is the pass's own measure of
      what it demanded, not a packet count.
  """
  @type report :: %{
          spaces: non_neg_integer(),
          agreed: non_neg_integer(),
          listed: [{Space.t(), non_neg_integer()}],
          absent: non_neg_integer(),
          asked: non_neg_integer()
        }

  @doc """
  Runs the pass over every live space in the mirror.

  Options: `:source` (defaults to the configured one) and `:spaces` (a list of
  live `%Space{}` to limit the pass to, which is what the admin screen uses when
  it re-checks one space).

  A space whose source failed is named in the report's `:failed` rather than
  ending the pass: a site with three hundred spaces should not lose the other
  two hundred and ninety-nine to one unreadable space.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    source = Keyword.get(opts, :source, Source.source())

    case live_spaces(opts) do
      [] ->
        %{spaces: 0, agreed: 0, listed: [], absent: 0, asked: 0, failed: [], empty: []}

      spaces ->
        # A `:counters` process keeps the request tally honest without threading
        # a number through every call site.
        tally = :counters.new(1, [])

        results = Enum.map(spaces, &check(source, &1, tally))

        report(spaces, results, :counters.get(tally, 1))
    end
  end

  defp live_spaces(opts) do
    case Keyword.get(opts, :spaces) do
      nil -> Mirror.list_spaces()
      spaces -> spaces
    end
  end

  # One space, in the cheapest way that settles it: a count when the source can
  # answer one, a listing when it cannot or when the count disagrees.
  defp check(source, space, tally) do
    case count(source, space, tally) do
      {:ok, upstream} ->
        if in_step?(upstream, space), do: {:agreed, space}, else: list(source, space, tally)

      _cannot_count ->
        list(source, space, tally)
    end
  end

  defp own_counts(space), do: Mirror.count_pages_by_type(space.id)

  # Two numbers are enough to know a space is in step: if the site and the mirror
  # count the same pages and posts, nothing can be missing and nothing can be
  # extra, so no page needs naming.
  #
  # Unless the space still carries absences. Those are only settled by naming the
  # ids — a count cannot tell a page that came back from a different page that
  # left, and leaving a page marked absent after it returned is worse than one
  # listing.
  defp in_step?(upstream, space) do
    own = own_counts(space)

    upstream.page == own.page and upstream.blogpost == own.blogpost and
      Mirror.count_absent(space.id) == 0
  end

  # A count is two requests (a page asks for one type at a time). A source that
  # cannot count, or whose count fails, simply says so and the space is listed.
  defp count(source, space, tally) do
    if function_exported?(source, :counts, 2) do
      :counters.add(tally, 1, 1)

      case source.counts(space.key, []) do
        {:ok, counts} -> {:ok, counts}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :cannot_count}
    end
  end

  # The id-only listing: the same pagination as a sync, with nothing in it.
  defp list(source, space, tally) do
    :counters.add(tally, 1, 1)

    case source.page_ids(space.key, []) do
      {:ok, %{page: [], blogpost: []}} ->
        {:empty, space}

      {:ok, ids} ->
        {marked, cleared} = Mirror.mark_absent(space, Map.values(ids) |> List.flatten())
        {:listed, space, marked, cleared}

      {:error, reason} ->
        {:failed, space, reason}
    end
  end

  defp report(spaces, results, asked) do
    %{
      spaces: length(spaces),
      agreed: Enum.count(results, &match?({:agreed, _}, &1)),
      listed: for({:listed, space, marked, _cleared} <- results, do: {space, marked}),
      absent: Mirror.count_absent(),
      asked: asked,
      failed: for({:failed, space, reason} <- results, do: {space.key, reason}),
      empty: for({:empty, space} <- results, do: space.key)
    }
  end
end
