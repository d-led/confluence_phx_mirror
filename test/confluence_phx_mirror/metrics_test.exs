defmodule ConfluencePhxMirror.MetricsTest do
  @moduledoc """
  The numbers an operator charts: what the mirror holds, what sits in its trash,
  who can read it, and what it costs on disk.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.{Metrics, Mirror}

  test "the measurements are the live totals, the trash, the accounts and both sizes" do
    space = space_fixture(%{name: "Engineering"})
    page_fixture(space, %{title: "Open", slug: "open"})
    doomed = space_fixture(%{name: "Doomed"})
    page_fixture(doomed, %{title: "Gone", slug: "gone"})
    user_fixture(%{email: "ops@example.com"})

    assert Mirror.trash_space(doomed) == 1

    measurements = Metrics.measurements()

    assert measurements.pages == 1
    assert measurements.spaces == 1
    assert measurements.trashed_pages == 1
    assert measurements.trashed_spaces == 1
    assert measurements.users >= 1
    assert measurements.blob_bytes >= 0
    assert measurements.database_bytes > 0
  end

  test "a run publishes the totals the moment it ends" do
    handler = {__MODULE__, :handle, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      [:confluence_mirror, :catalogue],
      fn _event, measurements, _metadata, pid -> send(pid, {:catalogue, measurements}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    demo_snapshot!()

    assert_receive {:catalogue, %{pages: pages, spaces: spaces, users: users}}, 5_000
    assert pages > 0
    assert spaces > 0
    assert users >= 0
  end

  test "every measurement is declared as a gauge the dashboard can chart" do
    names = Enum.map(ConfluencePhxMirrorWeb.Telemetry.metrics(), &Enum.join(&1.name, "."))

    for measurement <- Map.keys(Metrics.measurements()) do
      assert "confluence_mirror.catalogue.#{measurement}" in names,
             "#{measurement} is measured but not declared, so no chart shows it"
    end
  end
end
