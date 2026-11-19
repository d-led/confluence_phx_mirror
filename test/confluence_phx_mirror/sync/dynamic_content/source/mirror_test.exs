defmodule ConfluencePhxMirror.Sync.DynamicContent.Source.MirrorTest do
  @moduledoc """
  The two embeds whose content the mirror has to ask the site for.

  A board's document and a database's record are not in this mirror's database —
  the board is a canvas behind GraphQL, and the database's rows, though readable
  through experimental v2 resources, are not what this read is for. The reader
  gets an apology and a link either way, so the only place a reason can land is
  the run's log. Without that line a failed read is indistinguishable from a
  mirror that does not draw boards at all, which is exactly the reading that
  costs an afternoon.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Sync.DynamicContent.Source.Mirror
  alias ConfluencePhxMirror.Sync.Log
  alias ConfluencePhxMirror.TestConfig

  @site "https://acme.atlassian.net"
  @board "#{@site}/wiki/spaces/MFS/whiteboard/28344336"
  @database "#{@site}/wiki/spaces/MFS/database/29163537"
  @ari "ari:cloud:whiteboard::board/28344336"

  setup do
    TestConfig.put(HttpSource,
      base_url: @site,
      email: "mirror@acme.test",
      api_token: "secret-token",
      retries: 0,
      retry_backoff_ms: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    Log.clear()
    :ok
  end

  test "a database's record is what the page can honestly say about the box" do
    stub(fn conn -> Req.Test.json(conn, %{"id" => "29163537", "title" => "Roadmap"}) end)

    assert {:ok, %{"title" => "Roadmap"}} = Mirror.database(%Page{}, @database)
    assert warnings() == []
  end

  test "a record the site will not give is logged with its reason, never invented" do
    stub(fn conn -> Plug.Conn.resp(conn, 404, "gone") end)

    assert {:error, :not_found} = Mirror.database(%Page{}, @database)

    assert [warning] = warnings()
    assert warning.message =~ "a database could not be read: :not_found"
    assert warning.details == %{database: @database}
  end

  test "a board's document is the two reads the gateway takes" do
    stub(fn conn ->
      if String.contains?(conn.request_path, "graphql") do
        Req.Test.json(conn, %{"data" => %{"node" => document()}})
      else
        Req.Test.json(conn, %{"ari" => @ari})
      end
    end)

    assert {:ok, %{"WHITEBOARD_DOC_FORMAT" => 1}} = Mirror.whiteboard(%Page{}, @board)
    assert warnings() == []
  end

  test "a board the site will not give is logged with its reason" do
    stub(fn conn -> Plug.Conn.resp(conn, 404, "gone") end)

    assert {:error, :not_found} = Mirror.whiteboard(%Page{}, @board)

    assert [warning] = warnings()
    assert warning.message =~ "a whiteboard could not be read: :not_found"
    assert warning.details == %{whiteboard: @board}
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp warnings do
    for entry <- Log.entries(), entry.level == :warn, do: entry
  end

  # The gateway's answer, cut down to what the port reads.
  defp document do
    %{
      "body" => %{
        "whiteboardDocFormat" => %{
          "representation" => "{}",
          "value" => ~s({"WHITEBOARD_DOC_FORMAT": 1})
        }
      }
    }
  end
end
