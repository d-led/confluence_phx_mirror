defmodule ConfluencePhxMirror.Confluence.HttpSourceCallsTest do
  @moduledoc """
  What the client reports about its calls: one sync-log line per attempt, and
  the counters a run's summary is built from.

  The transport behaviour those calls exercise (URLs, credentials, retries,
  caps) lives next door in `HttpSourceClientTest`.
  """
  # The source reads its configuration from the application environment.
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.{HttpSource, Traffic}
  alias ConfluencePhxMirror.Sync.Log

  @base_url "https://acme.atlassian.net"

  setup do
    previous = Application.get_env(:confluence_phx_mirror, HttpSource)

    Application.put_env(
      :confluence_phx_mirror,
      HttpSource,
      base_url: @base_url,
      email: "mirror@acme.test",
      api_token: "secret-token",
      retries: 2,
      retry_backoff_ms: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    Log.clear()
    Traffic.reset()

    on_exit(fn ->
      Application.put_env(:confluence_phx_mirror, HttpSource, previous)
      Traffic.reset()
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  test "every attempt is a log line with its status, size and latency" do
    stub(fn conn -> Req.Test.json(conn, %{"results" => []}) end)

    assert {:ok, []} = HttpSource.pages("ENG", [])

    assert [first, second] = calls()

    assert first.level == :debug
    assert first.details.status == 200
    assert first.details.attempt == 1
    assert first.message =~ "GET /wiki/rest/api/content?limit=50&spaceKey=ENG"
    assert first.message =~ "200"

    assert second.details.status == 200
    assert Traffic.summary().requests == 2
  end

  test "a retried call is logged with the reason and counted" do
    stub(fn conn ->
      case Process.get(:attempt, 0) do
        0 ->
          Process.put(:attempt, 1)
          Plug.Conn.resp(conn, 429, "slow down")

        _ ->
          Req.Test.json(conn, %{"results" => []})
      end
    end)

    assert {:ok, []} = HttpSource.pages("ENG", [])

    assert %{level: :warn, message: message} = Enum.find(calls(), &(&1.level == :warn))

    assert message =~ "429"
    assert message =~ "retrying"

    summary = Traffic.summary()
    assert summary.retries == 1
    assert summary.statuses[429] == 1
    assert summary.failed == 0
  end

  test "a call that never succeeds is logged as an error and counted as a failure" do
    stub(fn conn -> Plug.Conn.resp(conn, 503, "maintenance") end)

    assert {:error, {:http, 503, "maintenance"}} = HttpSource.pages("ENG", [])

    assert [%{level: :error, message: message}] = Enum.filter(calls(), &(&1.level == :error))
    assert message =~ "503"
    assert message =~ "(2/2)"

    summary = Traffic.summary()
    assert summary.failed == 1
    assert summary.retries == 1
  end

  test "an absent page or group is an answer, not a failure" do
    stub(fn conn -> Plug.Conn.resp(conn, 404, "gone") end)

    assert {:error, :not_found} = HttpSource.pages("ENG", [])

    assert [%{level: :debug}] = calls()
    assert Traffic.summary().failed == 0
  end

  test "a download that leaves the site keeps its host in the line" do
    stub(fn
      %Plug.Conn{request_path: "/wiki/download/attachments/1002/diagram.svg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "https://api.media.atlassian.com/file/abc/download"
        )
        |> Plug.Conn.resp(302, "")

      %Plug.Conn{request_path: "/file/abc/download"} = conn ->
        Plug.Conn.resp(conn, 200, "<svg/>")
    end)

    attachment = %{download_url: "/wiki/download/attachments/1002/diagram.svg"}
    assert {:ok, "<svg/>"} = HttpSource.attachment_data(attachment, [])

    assert Enum.any?(calls(), &(&1.message =~ "GET api.media.atlassian.com/file/abc/download"))
  end

  defp calls, do: Log.entries() |> Enum.filter(&(&1.kind == :http))
end
