defmodule ConfluencePhxMirror.Confluence.HttpSourceDatabaseTest do
  @moduledoc """
  Reading a database: its columns in the order the database keeps them, the first
  rows, and the one question a still must never get wrong — whether the readers of
  the page may see those rows at all.

  A database can be restricted more narrowly than the page embedding it, and the
  graph carries no flag for that. The v1 restriction record does answer for a
  database, so any user or group named there stops the read: a stored body is
  served to every reader of the page, and a row somebody restricted must not
  become part of it.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.TestConfig

  @database "https://acme.atlassian.net/wiki/spaces/MFS/database/29163537"

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

  test "the table is the columns in order and the rows the mirror may draw" do
    Req.Test.stub(__MODULE__, fn conn -> answer(conn, rows: [row("One")]) end)

    assert {:ok, table} = HttpSource.database_table(@database)
    assert table["title"] == "Release log"
    assert table["fields"] == [field("f1", "Item")]
    assert table["entries"] == [row("One")]
    refute table["truncated"]
  end

  test "a table longer than a still draws keeps the first rows and says there are more" do
    Req.Test.stub(__MODULE__, fn conn ->
      answer(conn, rows: Enum.map(1..21, &row("Row #{&1}")))
    end)

    assert {:ok, table} = HttpSource.database_table(@database)
    assert length(table["entries"]) == 20
    assert table["truncated"]
  end

  test "a page that says more rows follow is truncated even when the count fits" do
    Req.Test.stub(__MODULE__, fn conn -> answer(conn, rows: [row("One")], more: true) end)

    assert {:ok, table} = HttpSource.database_table(@database)
    assert table["truncated"]
  end

  test "a column list that spans pages is followed to the end" do
    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        String.contains?(conn.request_path, "/restriction") ->
          Req.Test.json(conn, %{"results" => []})

        String.contains?(conn.request_path, "/fields") and conn.query_string =~ "cursor" ->
          Req.Test.json(conn, %{"results" => [field("f2", "Notes")]})

        String.contains?(conn.request_path, "/fields") ->
          Req.Test.json(conn, %{
            "results" => [field("f1", "Item")],
            "_links" => %{"next" => "/wiki/api/v2/databases/29163537/fields?cursor=abc"}
          })

        String.contains?(conn.request_path, "/entries") ->
          Req.Test.json(conn, %{"results" => [], "meta" => %{"hasMore" => false}})

        true ->
          Req.Test.json(conn, %{"title" => "Release log"})
      end
    end)

    assert {:ok, table} = HttpSource.database_table(@database)
    assert table["fields"] == [field("f1", "Item"), field("f2", "Notes")]
  end

  test "a restricted database comes back as its record, with no rows read" do
    Req.Test.stub(__MODULE__, fn conn ->
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

        String.contains?(conn.request_path, "/fields") or
            String.contains?(conn.request_path, "/entries") ->
          flunk("a restricted database was read further: #{conn.request_path}")

        true ->
          Req.Test.json(conn, %{"title" => "Release log"})
      end
    end)

    assert {:error, {:restricted, %{"title" => "Release log"}}} =
             HttpSource.database_table(@database)
  end

  test "something that is not a database never reaches the network" do
    Req.Test.stub(__MODULE__, fn conn -> flunk("requested #{conn.request_path}") end)

    assert {:error, {:not_a_database, _}} =
             HttpSource.database_table("https://acme.atlassian.net/wiki/spaces/MFS/pages/42")
  end

  defp answer(conn, options) do
    cond do
      String.contains?(conn.request_path, "/restriction") ->
        Req.Test.json(conn, %{"results" => []})

      String.contains?(conn.request_path, "/fields") ->
        Req.Test.json(conn, %{"results" => [field("f1", "Item")]})

      String.contains?(conn.request_path, "/entries") ->
        Req.Test.json(conn, %{
          "results" => Keyword.fetch!(options, :rows),
          "meta" => %{"hasMore" => Keyword.get(options, :more, false)}
        })

      true ->
        Req.Test.json(conn, %{"id" => "29163537", "title" => "Release log"})
    end
  end

  defp field(id, name), do: %{"id" => id, "name" => name, "type" => "text"}

  defp row(word), do: %{"values" => %{"f1" => %{"type" => "text", "plain" => word}}}
end
