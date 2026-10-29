defmodule ConfluencePhxMirror.Sync.SyncRunTest do
  @moduledoc """
  One run row, as the screens read it.

  The trigger is the only field with a history: it used to be one key of `stats`
  and it is a column now, so the reader has to answer for both shapes until an
  operator has moved the old rows across.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.SyncRun

  test "a run says why it happened" do
    run = %SyncRun{trigger: "the hourly schedule", stats: %{}}

    assert SyncRun.trigger(run) == "the hourly schedule"
  end

  test "a run nobody asked for has no trigger" do
    assert SyncRun.trigger(%SyncRun{trigger: nil, stats: %{"pages" => 3}}) == nil
  end

  test "a row written before the column keeps its answer in the stats it wrote" do
    run = %SyncRun{trigger: nil, stats: %{"trigger" => "the admin dashboard, by ops@acme.com"}}

    assert SyncRun.trigger(run) == "the admin dashboard, by ops@acme.com"
  end
end
