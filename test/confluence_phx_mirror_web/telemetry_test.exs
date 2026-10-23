defmodule ConfluencePhxMirrorWeb.TelemetryTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirrorWeb.Telemetry

  @catalogue [:confluence_mirror, :catalogue]
  @page_view [:confluence_mirror, :page, :view]

  setup do
    demo_snapshot!()
    listen([@catalogue, @page_view])
    :ok
  end

  test "the catalogue gauge says how much the mirror holds" do
    Telemetry.measure_catalogue()

    assert_receive {@catalogue, %{pages: 40, spaces: 2, attachments: attachments}, _}
    assert attachments > 0
  end

  test "opening a page counts as a read", %{conn: conn} do
    conn |> get("/spaces/ENG/pages/1002/Architecture+Overview") |> html_response(200)

    assert_receive {@page_view, %{count: 1}, %{kind: :page}}
  end

  test "a revalidation is not a read — nothing rendered, nothing counted", %{conn: conn} do
    first = conn |> get("/spaces/ENG/pages/1002/Architecture+Overview")
    assert_receive {@page_view, %{count: 1}, _}

    cached =
      conn
      |> Plug.Test.recycle_cookies(first)
      |> put_req_header("if-none-match", hd(get_resp_header(first, "etag")))
      |> get("/spaces/ENG/pages/1002/Architecture+Overview")

    assert cached.status == 304
    refute_receive {@page_view, %{count: 1}, _}
  end

  # A handler that forwards what it hears into this test process. The suite
  # runs other requests at the same time, so it is detached on exit.
  defp listen(events) do
    id = "#{__MODULE__}-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach_many(
      id,
      events,
      fn event, measurements, metadata, _config ->
        send(test, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
