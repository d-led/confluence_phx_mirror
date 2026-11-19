defmodule ConfluencePhxMirror.Confluence.HttpSourceSlideTest do
  @moduledoc """
  Reading a slide deck's record — which is all there is to read.

  A deck has no document on any surface: the graph's `ConfluenceSlide` node
  carries a title and links and no body, and the REST API offers no export. So
  the read is the same two-step the whiteboard takes (content record for the
  `ari`, then a query keyed by it), and the two things worth proving are the two
  that fail silently: a record with no `ari` cannot be asked about at all, and a
  URL that is not a deck must not reach the network.

  A node without a title is refused rather than carried around: the page would
  have nothing to say about it and would have to invent a name.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.TestConfig

  @deck_url "https://acme.atlassian.net/wiki/spaces/MFS/slides/29163538"
  @ari "ari:cloud:confluence:8096e94a-fe48-4395-b1e5-aedb3f31035b:slide/29163538"

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

  test "a deck's record comes back from the two reads it takes" do
    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        String.contains?(conn.request_path, "/content/") ->
          Req.Test.json(conn, %{"ari" => @ari})

        String.contains?(conn.request_path, "graphql") ->
          Req.Test.json(conn, %{"data" => %{"node" => deck_record()}})

        true ->
          flunk("unexpected request for #{conn.request_path}")
      end
    end)

    assert {:ok, %{"title" => "Half-year review", "latestVersion" => %{"number" => 4}}} =
             HttpSource.slide_record(@deck_url)
  end

  test "the record's version is asked for, because the card says which copy a reader has" do
    Req.Test.stub(__MODULE__, fn conn ->
      if String.contains?(conn.request_path, "/content/") do
        Req.Test.json(conn, %{"ari" => @ari})
      else
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"query" => query} = JSON.decode!(body)
        send(self(), {:query, query})
        Req.Test.json(conn, %{"data" => %{"node" => deck_record()}})
      end
    end)

    assert {:ok, _record} = HttpSource.slide_record(@deck_url)
    assert_received {:query, query}
    assert query =~ "latestVersion { number createdAt }"
  end

  test "the singular spelling of the address is the same deck" do
    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        String.contains?(conn.request_path, "/content/") ->
          Req.Test.json(conn, %{"ari" => @ari})

        String.contains?(conn.request_path, "graphql") ->
          Req.Test.json(conn, %{"data" => %{"node" => deck_record()}})

        true ->
          flunk("unexpected request for #{conn.request_path}")
      end
    end)

    singular = String.replace(@deck_url, "/slides/", "/slide/")

    assert {:ok, %{"title" => "Half-year review"}} = HttpSource.slide_record(singular)
  end

  test "a content record with no ari is refused before anything is queried" do
    Req.Test.stub(__MODULE__, fn conn ->
      if String.contains?(conn.request_path, "/content/") do
        Req.Test.json(conn, %{"id" => "29163538"})
      else
        flunk("the query ran without an ari to key it: #{conn.request_path}")
      end
    end)

    assert {:error, :no_ari} = HttpSource.slide_record(@deck_url)
  end

  test "something that is not a deck never reaches the network" do
    Req.Test.stub(__MODULE__, fn conn -> flunk("requested #{conn.request_path}") end)

    assert {:error, {:not_a_slide, _}} =
             HttpSource.slide_record("https://acme.atlassian.net/wiki/spaces/MFS/pages/42")
  end

  test "a gateway refusal says what it refused" do
    Req.Test.stub(__MODULE__, fn conn ->
      if String.contains?(conn.request_path, "/content/") do
        Req.Test.json(conn, %{"ari" => @ari})
      else
        Req.Test.json(conn, %{"errors" => [%{"message" => "Slides not enabled"}]})
      end
    end)

    assert {:error, {:graphql, "Slides not enabled"}} = HttpSource.slide_record(@deck_url)
  end

  test "a node with no title is refused instead of carried as a nameless deck" do
    Req.Test.stub(__MODULE__, fn conn ->
      if String.contains?(conn.request_path, "/content/") do
        Req.Test.json(conn, %{"ari" => @ari})
      else
        Req.Test.json(conn, %{"data" => %{"node" => %{"links" => %{"webUi" => @deck_url}}}})
      end
    end)

    assert {:error, :no_slide_record} = HttpSource.slide_record(@deck_url)
  end

  # The shape the gateway answers with, cut down to what is read.
  defp deck_record do
    %{
      "title" => "Half-year review",
      "latestVersion" => %{"number" => 4},
      "links" => %{"webUi" => @deck_url}
    }
  end
end
