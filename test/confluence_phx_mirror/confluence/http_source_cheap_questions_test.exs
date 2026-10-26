defmodule ConfluencePhxMirror.Confluence.HttpSourceCheapQuestionsTest do
  @moduledoc """
  The two requests a verify pass makes: how much a space holds, and which ids it
  holds — neither of which reads a page.

  What matters here is not only the answer but the request: a count is one small
  request per type, and an id listing asks for no expansion at all. That is the
  whole point of them, so it is asserted rather than assumed.
  """

  # The source reads its configuration from the application environment.
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource

  setup do
    previous = Application.get_env(:confluence_phx_mirror, HttpSource)

    Application.put_env(:confluence_phx_mirror, HttpSource,
      base_url: "https://acme.atlassian.net",
      email: "mirror@acme.test",
      api_token: "secret-token",
      retries: 1,
      retry_backoff_ms: 0,
      page_size: 50,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn -> Application.put_env(:confluence_phx_mirror, HttpSource, previous) end)
    :ok
  end

  describe "how much a space holds" do
    test "reads the site's own total, once per content type" do
      test_process = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_process, {:asked, conn.query_params})
        Req.Test.json(conn, %{"totalSize" => 42, "results" => []})
      end)

      assert {:ok, %{page: 42, blogpost: 42}} = HttpSource.counts("ENG", [])

      assert_received {:asked, %{"cql" => cql_pages, "limit" => "1"}}
      assert cql_pages =~ ~s(space="ENG")
      assert cql_pages =~ "type=page"

      assert_received {:asked, %{"cql" => cql_posts, "limit" => "1"}}
      assert cql_posts =~ "type=blogpost"
    end

    test "a site that sends no total is not guessed at" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"results" => []}) end)

      assert HttpSource.counts("ENG", []) == {:error, :no_total}
    end

    test "a space key cannot smuggle a clause into the query" do
      test_process = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_process, {:asked, conn.query_params["cql"]})
        Req.Test.json(conn, %{"totalSize" => 0, "results" => []})
      end)

      assert {:ok, _counts} = HttpSource.counts(~s(ENG" or type=page or space="X), [])

      assert_received {:asked, cql}
      refute cql =~ ~s(" or)
    end
  end

  describe "which ids a space holds" do
    test "names the ids and asks for nothing to be expanded" do
      test_process = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_process, {:asked, conn.query_params})

        ids = %{"page" => ["1002", "1003"], "blogpost" => ["2001"]}

        Req.Test.json(conn, %{
          "results" => Enum.map(ids[conn.query_params["type"]], &%{"id" => &1})
        })
      end)

      assert HttpSource.page_ids("ENG", []) == {:ok, %{page: [1002, 1003], blogpost: [2001]}}

      assert_received {:asked, page_query}
      assert page_query["type"] == "page"
      assert page_query["status"] == "current"
      refute Map.has_key?(page_query, "expand"), "a listing that names ids needs no bodies"

      assert_received {:asked, post_query}
      assert post_query["type"] == "blogpost"
    end
  end
end
