# The scale suite builds a mirror a thousand spaces wide before it measures
# anything, so it is opt-in: `mix test --only scale` (see `scale_test.exs`).
ExUnit.start(exclude: [:scale])
Ecto.Adapters.SQL.Sandbox.mode(ConfluencePhxMirror.Repo, :manual)

# One committed copy of the demo site, before any test opens a transaction.
#
# `demo_snapshot!` asks the sync for the demo site; on an empty database that is
# ~1.2 s of inserts, and it is what most of this suite spends its time on — not
# because the sync is slow but because it writes every page, comment, attachment
# and blob again in every test. With the site already mirrored the same call is
# a read and a compare: 134 ms, and it writes no page at all.
#
# Writing no page is the other half of the point. Two tests that both insert the
# same demo page ids meet on the same unique keys, and one waits for the other
# to commit — which is why seeded files have had to run one at a time. A run
# that finds nothing to write has nothing to collide on.
#
# This seed is committed, not part of a test's transaction: every test sees it,
# none rolls it back. It is idempotent — on a database that already has the site
# the run finds nothing to do.
Ecto.Adapters.SQL.Sandbox.unboxed_run(ConfluencePhxMirror.Repo, fn ->
  {:ok, _run} =
    ConfluencePhxMirror.Sync.run(:snapshot,
      gate: ConfluencePhxMirror.UnclaimedGate,
      trigger: "the test suite, once, before any test"
    )

  :ok
end)

# The base's blob files, so `Fixtures.clean_blobs/0` can tell what a *test* wrote
# from what the suite seeded before any test ran.
:persistent_term.put(
  {ConfluencePhxMirror.Fixtures, :base_blobs},
  ConfluencePhxMirror.Fixtures.blob_files()
)
