defmodule ConfluencePhxMirror.Confluence.HttpSourceDirectoryTest do
  @moduledoc """
  The client's reads about people rather than content: who an account is, who may
  read a space, who is in a group, and the probe an operator points at a site
  before believing the mirror can reach it.

  These answer questions the reader check asks on every page, so the shapes here
  are the site's own — a Cloud space expands its permissions onto the space
  itself, a member carries only the identifiers the site is willing to share, and
  a group is addressed by id because a name answers 404.
  """

  # The source reads its configuration from the application environment.
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.TestConfig

  @base_url "https://acme.atlassian.net"

  setup do
    TestConfig.put(HttpSource,
      base_url: @base_url,
      email: "mirror@acme.test",
      api_token: "secret-token",
      retries: 0,
      retry_backoff_ms: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    :ok
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  # Every answer screens the request it answered, so a test can say which URL the
  # client asked — not only what it made of the reply.
  defp serve(body) do
    test_process = self()

    stub(fn conn ->
      send(test_process, {:asked, conn.request_path, conn.query_string})
      Req.Test.json(conn, body)
    end)
  end

  defp assert_asked(path, query) do
    assert_received {:asked, ^path, ^query}
  end

  describe "the probe" do
    test "says which site it reached, and who the token is" do
      serve(%{
        "displayName" => "Mirror Bot",
        "email" => "mirror@acme.test",
        "accountId" => "5b10ac8d82e05b22cc7d4ef5"
      })

      assert {:ok,
              %{
                base_url: @base_url,
                display_name: "Mirror Bot",
                email: "mirror@acme.test",
                account_id: "5b10ac8d82e05b22cc7d4ef5"
              }} = HttpSource.probe()

      assert_asked("/wiki/rest/api/user/current", "")
    end

    # A probe with nowhere to point is answered before any request, so a
    # misconfigured tool does not report the site's own errors as its own.
    test "with no site configured it asks nothing at all" do
      TestConfig.put(HttpSource, base_url: nil)
      serve(%{})

      assert {:error, :missing_base_url} = HttpSource.probe()
      refute_received {:asked, _path, _query}
    end
  end

  describe "an account's status" do
    test "answers what the site says about it, and names the account in the query" do
      serve(%{
        "accountStatus" => "active",
        "email" => "jane@acme.test",
        "displayName" => "Jane Doe"
      })

      assert {:ok,
              %{
                account_status: "active",
                email: "jane@acme.test",
                display_name: "Jane Doe"
              }} = HttpSource.user_status("557058:jane.doe", [])

      # The id holds a colon, and a colon in a query value has to be escaped or
      # the site answers about a different account.
      assert_asked("/wiki/rest/api/user", "accountId=557058%3Ajane.doe")
    end
  end

  describe "who may read a space" do
    test "only the read grant becomes a subject, per identifier the site gave" do
      serve(space_with_grants())

      assert {:ok, subjects} = HttpSource.space_permissions("ENG", [])

      # The expanded permissions ride on the space itself; `/space/{key}/permissions`
      # is a 404 on Cloud.
      assert_asked("/wiki/rest/api/space/ENG", "expand=permissions")

      assert %{operation: "read", subject_type: "user", subject_key: "5b10ac8d"} in subjects
      assert %{operation: "read", subject_type: "user", subject_key: "jane@acme.test"} in subjects

      # A group is matched case-insensitively, so the stored key is the normalised
      # one — and the write grant beside it is none of a reader's business.
      assert %{operation: "read", subject_type: "group", subject_key: "confluence-users"} in subjects
      refute Enum.any?(subjects, &(&1.operation == "write"))
      refute Enum.any?(subjects, &(&1.subject_type == "group" and &1.subject_key == "Writers"))
    end

    test "anonymous access is a subject of its own" do
      serve(%{
        "permissions" => [
          %{
            "operation" => %{"operation" => "read"},
            "anonymousAccess" => true,
            "subjects" => %{"user" => %{"results" => []}, "group" => %{"results" => []}}
          }
        ]
      })

      assert {:ok, subjects} = HttpSource.space_permissions("ENG", [])
      assert subjects == [%{operation: "read", subject_type: "anonymous", subject_key: nil}]
    end

    test "a space that lists no permissions is open, not an error" do
      serve(%{"key" => "ENG", "name" => "Engineering"})

      assert {:ok, []} = HttpSource.space_permissions("ENG", [])
    end
  end

  describe "a group's members" do
    test "each page is handed on as it arrives, and the count is the whole group" do
      test_process = self()

      stub(fn conn ->
        send(test_process, {:asked, conn.request_path, conn.query_string})

        case conn.query_string do
          "limit=" <> _ ->
            Req.Test.json(conn, %{
              "results" => [%{"accountId" => "5b10ac8d", "email" => "jane@acme.test"}],
              "_links" => %{"next" => "/rest/api/group/42/membersByGroupId?cursor=second"}
            })

          _second_page ->
            Req.Test.json(conn, %{
              "results" => [%{"accountId" => "bot-1", "displayName" => "Automation"}]
            })
        end
      end)

      sink = fn page -> send(test_process, {:page, page}) end

      assert {:ok, 2} = HttpSource.each_group_member_page(%{id: "42"}, [], sink)

      # The next link is relative to the REST root and already carries
      # `/rest/api`; asking the site for it verbatim would be a 404.
      assert_asked("/wiki/rest/api/group/42/membersByGroupId", "cursor=second")

      assert_received {:page, [%{account_id: "5b10ac8d", email: "jane@acme.test"}]}
      # An app account has no address at all, so its id is its identity.
      assert_received {:page, [%{account_id: "bot-1", email: nil, display_name: "Automation"}]}
    end

    test "a group known only by name is refused, because a name answers 404" do
      serve(%{})

      assert {:error, {:no_group_id, "confluence-users"}} =
               HttpSource.each_group_member_page(%{name: "confluence-users"}, [], fn _ -> :ok end)

      refute_received {:asked, _path, _query}
    end
  end

  describe "a database's record" do
    test "the page's own address names the record, which is read from REST v2" do
      serve(%{"id" => "29163537", "title" => "Roadmap"})

      assert {:ok, %{"title" => "Roadmap"}} =
               HttpSource.database_record(
                 "https://acme.atlassian.net/wiki/spaces/MFS/database/29163537"
               )

      assert_asked("/wiki/api/v2/databases/29163537", "")
    end

    # A body link that only looks like a database is not one, and the message
    # quotes the address back rather than blaming the site.
    test "an address that is not a database is refused, and quoted back" do
      serve(%{})
      page_url = "https://acme.atlassian.net/wiki/spaces/MFS/page/2916"

      assert {:error, {:not_a_database, ^page_url}} = HttpSource.database_record(page_url)

      refute_received {:asked, _path, _query}
    end
  end

  defp space_with_grants do
    %{
      "key" => "ENG",
      "permissions" => [
        %{
          "operation" => %{"operation" => "read"},
          "anonymousAccess" => false,
          "subjects" => %{
            "user" => %{
              "results" => [%{"accountId" => "5b10ac8d", "email" => "jane@acme.test"}]
            },
            "group" => %{"results" => [%{"name" => " Confluence-Users "}]}
          }
        },
        %{
          "operation" => %{"operation" => "write"},
          "subjects" => %{
            "user" => %{"results" => []},
            "group" => %{"results" => [%{"name" => "Writers"}]}
          }
        }
      ]
    }
  end
end
