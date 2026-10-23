defmodule ConfluencePhxMirror.Sync.Cancelled do
  @moduledoc """
  Raised inside a run that an administrator asked to stop.

  A sync cannot be killed from outside without leaving a half-written page
  behind, so cancellation is cooperative: the pipeline checks between pages —
  never inside one — and raises this to leave the loops from wherever they are.
  `Sync.run/2` turns it into a `cancelled` run; nothing else catches it.
  """

  defexception message: "the run was cancelled"
end
