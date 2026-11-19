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

  A still's *names* are the other half: a database row that holds a person is
  drawn with the name the mirror already holds for that account, which is a read
  of this mirror's own table — no site call, and nothing to fall back to when the
  row is missing.
  """

  use ConfluencePhxMirror.DataCase, async: false

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

  test "a database's table is what the page draws" do
    stub(fn conn ->
      cond do
        String.contains?(conn.request_path, "/restriction") ->
          Req.Test.json(conn, %{"results" => []})

        String.contains?(conn.request_path, "/fields") ->
          Req.Test.json(conn, %{"results" => [field()]})

        String.contains?(conn.request_path, "/entries") ->
          Req.Test.json(conn, %{"results" => [entry("One")], "meta" => %{"hasMore" => false}})

        true ->
          Req.Test.json(conn, %{"id" => "29163537", "title" => "Roadmap"})
      end
    end)

    assert {:ok, table} = Mirror.database(%Page{}, @database)
    assert table["title"] == "Roadmap"
    assert table["fields"] == [field()]
    assert table["entries"] == [entry("One")]
    refute table["truncated"]
    assert warnings() == []
  end

  test "a restricted database is named, and its rows are not read" do
    stub(fn conn ->
      cond do
        String.contains?(conn.request_path, "/restriction") ->
          Req.Test.json(conn, %{
            "results" => [
              %{
                "operation" => "read",
                "restrictions" => %{"user" => %{"size" => 1}, "group" => %{"size" => 0}}
              }
            ]
          })

        String.contains?(conn.request_path, "/entries") or
            String.contains?(conn.request_path, "/fields") ->
          flunk("rows were read from a restricted database: #{conn.request_path}")

        true ->
          Req.Test.json(conn, %{"id" => "29163537", "title" => "Roadmap"})
      end
    end)

    assert {:ok, table} = Mirror.database(%Page{}, @database)
    assert table["title"] == "Roadmap"
    assert table["fields"] == []
    assert [warning] = warnings()
    assert warning.message =~ "a database is restricted"
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

  describe "a person a still names" do
    test "is the name the mirror holds" do
      ConfluencePhxMirror.Mirror.upsert_person(%{
        account_id: "acc-ada",
        display_name: "Ada Lovelace"
      })

      assert Mirror.person(%Page{}, "acc-ada") == "Ada Lovelace"
    end

    test "is unknown for an empty account" do
      assert Mirror.person(%Page{}, "") == nil
    end

    test "is read from the site when the mirror has never seen the account, and only once" do
      calls = :ets.new(:calls, [:public, :set])
      :ets.insert(calls, {:user, 0})

      stub(fn conn ->
        :ets.update_counter(calls, :user, 1)

        Req.Test.json(conn, %{
          "accountId" => "acc-ada",
          "displayName" => "Ada Lovelace",
          "accountType" => "atlassian"
        })
      end)

      assert Mirror.person(%Page{}, "acc-ada") == "Ada Lovelace"
      assert Mirror.person(%Page{}, "acc-ada") == "Ada Lovelace"
      assert :ets.lookup_element(calls, :user, 2) == 1
    end

    test "is unknown when the site has no such account, and stores nothing" do
      stub(fn conn -> Plug.Conn.resp(conn, 404, "{}") end)

      assert Mirror.person(%Page{}, "acc-nobody") == nil
      assert ConfluencePhxMirror.Mirror.find_person("acc-nobody") == nil
      assert warnings() == []
    end

    test "is remembered without throwing away a face the mirror already had" do
      ConfluencePhxMirror.Mirror.upsert_person(%{
        account_id: "acc-ada",
        display_name: "Ada Lovelace",
        avatar_blob_key: "people/acc-ada/png",
        avatar_media_type: "image/png"
      })

      ConfluencePhxMirror.Mirror.remember_person_name("acc-ada", "A. Lovelace")

      assert %{display_name: "Ada Lovelace", avatar_blob_key: "people/acc-ada/png"} =
               ConfluencePhxMirror.Mirror.find_person("acc-ada")
    end
  end

  describe "the page a person gets here" do
    test "answers for somebody whose byline is on a mirrored page" do
      page =
        ConfluencePhxMirror.Fixtures.page_fixture(ConfluencePhxMirror.Fixtures.space_fixture(), %{
          author_account_id: "acc-ada"
        })

      assert Mirror.person_page?(%Page{}, page.author_account_id)
    end

    test "does not answer for a stranger who is only a cell in a table" do
      refute Mirror.person_page?(%Page{}, "acc-stranger")
    end
  end

  describe "the label a still names" do
    test "is held when some mirrored page carries it" do
      space = ConfluencePhxMirror.Fixtures.space_fixture()
      page = ConfluencePhxMirror.Fixtures.page_fixture(space)
      ConfluencePhxMirror.Mirror.replace_labels(page, ["test"])

      assert Mirror.label?(%Page{}, "test")
    end

    test "is not held when no page here carries it" do
      refute Mirror.label?(%Page{}, "test")
    end
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp warnings do
    for entry <- Log.entries(), entry.level == :warn, do: entry
  end

  # A column and a row as the v2 resources answer them, cut down to what the
  # port reads.
  defp field, do: %{"id" => "f1", "name" => "Item", "type" => "text"}

  defp entry(word), do: %{"values" => %{"f1" => %{"type" => "text", "plain" => word}}}

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
