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

  ## Surviving an interruption

  A site of a thousand spaces takes a while, and a long job meets deploys. Each
  space is therefore settled and *recorded* on its own
  (`ReconcileObservation`), and an unfinished pass is continued rather than
  restarted — a resumed attempt asks only about the spaces the last one did not
  reach, and its report covers the whole pass. Each fact carries the time it was
  observed, because a pass resumed hours later is old at its first space.
  """

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Space
  alias ConfluencePhxMirror.Sync.ReconcileRun

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
  Runs the pass over every live space in the mirror, continuing an interrupted
  one.

  Options: `:source` (defaults to the configured one) and `:trigger` (why the
  pass happened, kept for the record).

  A space whose source failed is named in the report's `:failed` rather than
  ending the pass: a site with three hundred spaces should not lose the other
  two hundred and ninety-nine to one unreadable space.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    source = Keyword.get(opts, :source, Source.source())
    # A pass leaves a record whether or not it finishes: an interrupted one has
    # still marked absences, and the screen must be able to say when it last
    # knew rather than guess.
    # A pass that was interrupted is continued, not restarted: the spaces it
    # recorded are done, and asking the site the same question twice is the cost
    # this pass exists to avoid.
    run_record = ReconcileRun.resume_or_start(%{trigger: Keyword.get(opts, :trigger)})

    Enum.each(pending_spaces(run_record), &settle(source, run_record, &1))

    report = run_record |> ReconcileRun.facts() |> summarise(Mirror.count_absent())
    ReconcileRun.finish(run_record, report)

    report
  end

  # The spaces this pass has not settled yet, which is the whole list on a first
  # attempt and the remainder on a resumed one.
  defp pending_spaces(run_record) do
    settled = ReconcileRun.observed_space_ids(run_record)

    Enum.reject(Mirror.list_spaces(), &MapSet.member?(settled, &1.id))
  end

  # One space, in the cheapest way that settles it. The recorded fact is written
  # only after the marking, so a pass never claims work it did not do; a pass
  # killed in between repeats one space, and marking is idempotent.
  defp settle(source, run_record, space) do
    {space, fact} = check(source, space)
    ReconcileRun.observe(run_record, space, fact)
  end

  # A count is one question; a space the count could not settle costs that
  # question and a listing, which is what the observation records. Whether the
  # count was available at all is recorded too: on a Confluence that cannot report
  # a per-space total, every space is listed in full, and the screen says so
  # rather than letting "nothing absent" look cheap.
  defp check(source, space) do
    case count(source, space) do
      {:ok, upstream} ->
        if in_step?(upstream, space),
          do: fact(space, :agreed, asked: 1, counted: true),
          else: list(source, space, true)

      _cannot_count ->
        list(source, space, false)
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
  defp count(source, space) do
    if function_exported?(source, :counts, 2) do
      case source.counts(space.key, []) do
        {:ok, counts} -> {:ok, counts}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :cannot_count}
    end
  end

  # The id-only listing: the same pagination as a sync, with nothing in it.
  defp list(source, space, counted?) do
    asked = if counted?, do: 2, else: 1

    case source.page_ids(space.key, []) do
      {:ok, %{page: [], blogpost: []}} ->
        fact(space, :empty, asked: asked, counted: counted?)

      {:ok, ids} ->
        named = ids |> Map.values() |> List.flatten()
        {marked, cleared} = Mirror.mark_absent(space, named)

        fact(space, :listed,
          asked: asked,
          counted: counted?,
          named: length(named),
          marked: marked,
          cleared: cleared
        )

      {:error, reason} ->
        fact(space, :failed, asked: asked, counted: counted?, error: error_text(reason))
    end
  end

  defp fact(space, verdict, attrs) do
    default = %{
      verdict: verdict,
      asked: 0,
      counted: false,
      named: 0,
      marked: 0,
      cleared: 0,
      error: nil
    }

    {space, Map.merge(default, Map.new(attrs))}
  end

  # The record is read by people and by grep, so a reason is text and not a term.
  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_text(reason), do: inspect(reason)

  # The report is a summary of the facts, not of this attempt: a pass resumed
  # after an interruption reports every space it settled, not just the last few.
  defp summarise(facts, absent) do
    %{
      spaces: length(facts),
      agreed: Enum.count(facts, &(&1.verdict == "agreed")),
      listed: for(%{verdict: "listed"} = fact <- facts, do: {fact.space, fact.marked}),
      absent: absent,
      asked: facts |> Enum.map(& &1.asked) |> Enum.sum(),
      failed: for(%{verdict: "failed"} = fact <- facts, do: {fact.space.key, fact.error}),
      empty: for(%{verdict: "empty"} = fact <- facts, do: fact.space.key)
    }
  end
end
