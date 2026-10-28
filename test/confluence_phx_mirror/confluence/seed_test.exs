defmodule ConfluencePhxMirror.Confluence.SeedTest do
  @moduledoc """
  The seeder is the only code that writes to Confluence, so its guard rails are
  pinned here: planning is read-only, repeats create nothing, and content the
  seeder did not create is never touched.
  """
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.{DemoContent, HttpSource, Seed}
  alias ConfluencePhxMirror.TestConfig

  @space_path "/wiki/rest/api/space/ENG"
  @content_path "/wiki/rest/api/content"

  setup do
    TestConfig.put(
      HttpSource,
      base_url: "https://acme.atlassian.net",
      email: "mirror@acme.test",
      api_token: "secret-token",
      retries: 1,
      retry_backoff_ms: 0,
      requests_per_second: 1_000,
      burst: 1_000,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    :ok
  end

  describe "deciding what to create" do
    test "a missing page is created" do
      assert [%{title: "Getting Started", action: :create}] =
               Seed.decide([%{title: "Getting Started"}], %{})
    end

    test "a page the seeder already created is left alone" do
      existing = %{"Getting Started" => %{id: 42, ours?: true}}

      assert [%{action: :exists, page_id: 42}] =
               Seed.decide([%{title: "Getting Started"}], existing)
    end

    test "a page a human wrote is reported, never overwritten" do
      existing = %{"Getting Started" => %{id: 7, ours?: false}}

      assert [%{action: :foreign, page_id: 7}] =
               Seed.decide([%{title: "Getting Started"}], existing)
    end
  end

  describe "planning" do
    test "a human's page is reported as foreign, a missing one as to create" do
      stub(fn
        %Plug.Conn{method: "GET", request_path: @content_path} = conn ->
          Req.Test.json(conn, %{"results" => [page_json("Engineering Handbook", [])]})

        conn ->
          allow_reads(conn)
      end)

      {:ok, decisions} = Seed.plan("ENG")

      assert %{action: :foreign} = Enum.find(decisions, &(&1.title == "Engineering Handbook"))
      assert Enum.any?(decisions, &(&1.action == :create))
    end

    test "planning writes nothing" do
      parent = self()

      stub(fn conn ->
        send(parent, {:request, conn.method})
        allow_reads(conn)
      end)

      {:ok, _decisions} = Seed.plan("ENG")

      assert_received {:request, "GET"}
      refute_received {:request, "POST"}
      refute_received {:request, "PUT"}
    end
  end

  describe "running" do
    test "refuses to write when the account cannot administer the space" do
      stub(fn
        %Plug.Conn{method: "GET", request_path: @space_path} = conn ->
          Req.Test.json(conn, %{"key" => "ENG"})

        conn ->
          allow_reads(conn)
      end)

      assert Seed.run("ENG") == {:error, :not_admin}
    end

    test "creates the missing pages, then labels them" do
      parent = self()

      stub(fn conn ->
        send(parent, {:request, conn.method, conn.request_path})

        case conn do
          %Plug.Conn{method: "POST", request_path: @content_path} ->
            Req.Test.json(conn, %{"id" => "1"})

          %Plug.Conn{method: "POST"} ->
            Req.Test.json(conn, %{})

          _read ->
            allow_reads(conn)
        end
      end)

      assert {:ok, notes} = Seed.run("ENG")

      assert notes |> Enum.map(& &1.action) |> Enum.uniq() |> Enum.sort() == [:create, :extras]
      assert_received {:request, "POST", @content_path}
      assert_received {:request, "POST", "/wiki/rest/api/content/1/label"}
    end

    test "a second run creates nothing" do
      stub(fn conn -> seeded_site(conn) end)

      assert {:ok, notes} = Seed.run("ENG")

      refute Enum.any?(notes, &(&1.action == :create))
      assert Enum.any?(notes, &(&1.action == :exists))
    end
  end

  # The site right after a successful seed: every demo page of ENG exists and
  # carries the seeder's label.
  defp seeded_site(%Plug.Conn{method: "GET", request_path: @content_path} = conn) do
    pages =
      for page <- DemoContent.pages(), page.space_key == "ENG" do
        page_json(page.title, [%{"name" => Seed.label()}])
      end

    Req.Test.json(conn, %{"results" => pages})
  end

  defp seeded_site(conn), do: allow_reads(conn)

  defp allow_reads(%Plug.Conn{method: "GET", request_path: @content_path} = conn),
    do: Req.Test.json(conn, %{"results" => []})

  defp allow_reads(conn), do: Req.Test.json(conn, %{"permissions" => [%{"operation" => "read"}]})

  defp page_json(title, labels) do
    %{"id" => "1", "title" => title, "metadata" => %{"labels" => %{"results" => labels}}}
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)
end
