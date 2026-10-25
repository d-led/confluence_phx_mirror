defmodule ConfluencePhxMirror.MetricsHistoryTest do
  @moduledoc """
  The store that gives the dashboard's charts a past: it records the catalogue
  gauges as they are published, and answers the callback with what it has.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.MetricsHistory

  test "the points published for a metric come back, in time order" do
    for pages <- [10, 11] do
      :telemetry.execute([:confluence_mirror, :catalogue], %{pages: pages}, %{})
    end

    settle()

    history = MetricsHistory.metrics_history(%{name: [:confluence_mirror, :catalogue, :pages]})

    assert history != []
    assert List.last(history).measurement == 11
    assert Enum.map(history, & &1.time) == Enum.sort(Enum.map(history, & &1.time))
    assert Enum.all?(history, &(&1.label == nil))
  end

  test "a metric nobody recorded has no history, rather than an invented one" do
    assert MetricsHistory.metrics_history(%{name: [:vm, :memory, :total]}) == []
  end

  # The store records through a cast: waiting on its state is how the rest of
  # the suite synchronises with a process, and it keeps the sleep out of the
  # test.
  defp settle, do: _ = :sys.get_state(MetricsHistory)
end
