defmodule ConfluencePhxMirror.Confluence.HttpSourceWhiteboardTest do
  @moduledoc """
  Reading a board's document, which is the one read a board cannot do without.

  A whiteboard has no REST representation: the Whiteboard API is create /
  metadata / delete, and `body.export_view` carries a placeholder. The drawing
  lives behind Confluence's GraphQL gateway, and it takes two reads to get there —
  the content record for the board's `ari`, then a query keyed by it.

  So the two things worth proving are the two that fail silently: a board with no
  `ari` cannot be asked about at all, and a URL that is not a board must not
  reach the network. Both are cheap to state and neither is visible from the
  renderer's side.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.TestConfig

  @board_url "https://acme.atlassian.net/wiki/spaces/MFS/whiteboard/28344336"
  @ari "ari:cloud:whiteboard::board/28344336"

  setup do
    TestConfig.put(HttpSource,
      base_url: "https://acme.atlassian.net",
      email: "mirror@acme.test",
      api_token: "secret-token",
      retries: 0,
      retry_backoff_ms: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    :ok
  end

  test "a board's document comes back from the two reads it takes" do
    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        String.contains?(conn.request_path, "/content/") ->
          Req.Test.json(conn, %{"ari" => @ari})

        String.contains?(conn.request_path, "graphql") ->
          Req.Test.json(conn, %{"data" => %{"node" => drawn()}})

        true ->
          flunk("unexpected request for #{conn.request_path}")
      end
    end)

    assert {:ok, document} = HttpSource.whiteboard_document(@board_url)
    assert document == %{"WHITEBOARD_DOC_FORMAT" => 1}
  end

  test "a content record with no ari is refused before anything is queried" do
    # The graph is keyed by the ARI; without one there is nothing to ask, and a
    # second request would be a guess at the site's expense.
    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        String.contains?(conn.request_path, "/content/") ->
          Req.Test.json(conn, %{"id" => "28344336"})

        true ->
          flunk("the query ran without an ari to key it: #{conn.request_path}")
      end
    end)

    assert {:error, :no_ari} = HttpSource.whiteboard_document(@board_url)
  end

  test "something that is not a board never reaches the network" do
    Req.Test.stub(__MODULE__, fn conn -> flunk("requested #{conn.request_path}") end)

    assert {:error, {:not_a_whiteboard, _}} =
             HttpSource.whiteboard_document("https://acme.atlassian.net/wiki/spaces/MFS/pages/42")
  end

  # The shape the gateway answers with, cut down to what is read.
  defp drawn do
    %{
      "body" => %{
        "whiteboardDocFormat" => %{
          "representation" => "{\"version\":2}",
          "value" => ~s({"WHITEBOARD_DOC_FORMAT": 1})
        }
      }
    }
  end
end
