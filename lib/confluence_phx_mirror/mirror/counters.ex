defmodule ConfluencePhxMirror.Mirror.Counters do
  @moduledoc """
  Content-derived totals, remembered until the content moves.

  The home page says how many pages the mirror holds and how many each space
  has; answering that is a scan of every page, and a scan per request is what a
  mirror with a million pages cannot afford. The numbers only change when
  something writes — a sync, a space trashed or purged, a fixture in the test
  suite — so they are cached against the newest write in the mirror
  (`max(pages.id)`, `max(pages.updated_at)` and the live space count) rather than
  against a timer: a quiet mirror pays one query per request, a changed one pays
  the scan once.

  Every write the mirror makes moves that version: an insert, an update of a
  rendered body, a deletion (which sets `updated_at` as well as `deleted_at`),
  and a space that appears or leaves. A rolled-back transaction is the one thing
  it cannot see, which is why the test suite calls `clear/0` instead of trusting
  it.

  The table belongs to this process, which the application supervisor starts and
  keeps: a cache owned by whichever request created it would disappear with that
  request.
  """

  use GenServer

  import Ecto.Query

  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Repo

  @table __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  @doc "The value cached under `key`, computed on a miss and kept until the content moves."
  def fetch(key, compute) do
    version = version()
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, ^version, value}] ->
        value

      _stale_or_missing ->
        value = compute.()
        store(key, version, value)
        value
    end
  end

  @doc """
  The content version the cached totals were computed from.

  Three readings in one index probe: the newest row (a page that arrived), the
  newest page write (a page that changed, was rendered or was marked deleted),
  and the number of live spaces (a space that appeared, was trashed or was
  purged — a space with no pages would otherwise move no version at all). The
  timestamp alone would not be enough — it has second precision, and two writes
  in the same second are still two versions.
  """
  def version do
    Repo.one(
      from p in Page,
        select:
          {max(p.id), max(p.updated_at),
           fragment("(SELECT count(*) FROM spaces WHERE deleted_at IS NULL)")}
    )
  end

  @doc "Forgets every cached total; the next read computes it again."
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Recomputes everything the home page prints.

  A sync calls this when it finishes: the first reader after a sync would
  otherwise wait for the scans, and the sync is the process that made them
  necessary.
  """
  def warm do
    ConfluencePhxMirror.Mirror.stats()
    ConfluencePhxMirror.Mirror.spaces_with_counts()
    :ok
  end

  # Only this key's stale value goes: other keys may still be valid, and a key
  # is fetched again the next time that screen asks for it.
  defp store(key, version, value) do
    :ets.match_delete(@table, {key, :_, :_})
    :ets.insert(@table, {key, version, value})
    value
  end

  # A script or a test may ask before the application has started the owner;
  # two processes can find the table missing at the same time, and the loser
  # adopts the winner's.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> create_table()
      _existing -> @table
    end
  end

  defp create_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  rescue
    ArgumentError -> @table
  end
end
