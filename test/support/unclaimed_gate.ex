defmodule ConfluencePhxMirror.UnclaimedGate do
  @moduledoc """
  A sync gate that never refuses, for a caller that already owns the mirror.

  `Sync.Gate` keeps two runs apart by claiming one row, which is what a mirror
  with a pool, two Machines and a deploy loop needs. A test is not that mirror:
  the sandbox hands it a database of its own, so the run inside the test is the
  only run in that database and there is nothing to exclude. Being an
  `INSERT … ON CONFLICT` on a single row, the real gate also makes every
  concurrent test wait for the one holding it, which turns a suite that should
  overlap into a queue.

      {:ok, run} = Sync.run(:snapshot, gate: ConfluencePhxMirror.UnclaimedGate)
  """

  @doc "Runs `fun` without claiming anything."
  @spec exclusive((nil -> result)) :: {:ok, result} when result: term()
  def exclusive(fun), do: {:ok, fun.(nil)}
end
