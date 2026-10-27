defmodule ConfluencePhxMirror.Confluence.HttpSourceClientTest do
  @moduledoc """
  The HTTP side of the Confluence client: URL building, credentials, retries,
  response caps and the DTOs the sync pipeline consumes.

  Parsing of page restrictions lives next door in `HttpSourceTest`.
  """
  # The source reads its configuration from the application environment.
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource

  @base_url "https://acme.atlassian.net"

  setup do
    previous = Application.get_env(:confluence_phx_mirror, HttpSource)
    put_config([])
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, HttpSource, previous) end)
    :ok
  end

  defp put_config(opts) do
    base = [
      base_url: @base_url,
      email: "mirror@acme.test",
      api_token: "secret-token",
      retries: 2,
      retry_backoff_ms: 0,
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    Application.put_env(:confluence_phx_mirror, HttpSource, Keyword.merge(base, opts))
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp page_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "1002",
        "type" => "page",
        "status" => "current",
        "title" => "Architecture Overview",
        "space" => %{"key" => "ENG"},
        "ancestors" => [%{"id" => "1000"}, %{"id" => "1001"}],
        "version" => %{
          "number" => 15,
          "message" => "tidied",
          "when" => "2026-10-02T10:00:00.000Z",
          "by" => %{"displayName" => "Jane Doe", "accountId" => "acc-1"}
        },
        "body" => %{
          "storage" => %{"value" => "<p>storage body</p>"},
          "export_view" => %{"value" => "<p>export body</p>"}
        },
        "metadata" => %{"labels" => %{"results" => [%{"name" => "architecture"}]}},
        "history" => %{"createdDate" => "2026-10-01T09:00:00.000Z"},
        "_links" => %{"webui" => "/spaces/ENG/pages/1002/Architecture+Overview"}
      },
      overrides
    )
  end

  describe "pages/2" do
    test "maps Confluence content into a mirror DTO" do
      stub(fn conn ->
        assert conn.request_path == "/wiki/rest/api/content"
        assert conn.query_params["spaceKey"] == "ENG"
        # Cloud returns nothing for a comma-separated type list, so each type is
        # asked for on its own.
        assert conn.query_params["type"] in ["page", "blogpost"]
        Req.Test.json(conn, %{"results" => [page_json()]})
      end)

      assert {:ok, [page, _post]} = HttpSource.pages("ENG", [])

      assert page.id == 1002
      assert page.title == "Architecture Overview"
      assert page.space_key == "ENG"
      assert page.ancestors == [1000, 1001]
      assert page.parent_id == 1001
      assert page.labels == ["architecture"]
      assert page.body.storage == "<p>storage body</p>"
      assert page.body.export_view == "<p>export body</p>"
      assert page.url == "#{@base_url}/wiki/spaces/ENG/pages/1002/Architecture+Overview"
      assert page.created_at == ~U[2026-10-01 09:00:00.000Z]
      assert page.updated_at == ~U[2026-10-02 10:00:00.000Z]

      assert page.version == %{
               number: 15,
               message: "tidied",
               when: ~U[2026-10-02 10:00:00.000Z],
               by: %{display_name: "Jane Doe", account_id: "acc-1"}
             }
    end

    test "keeps the instant when Confluence writes it in another offset" do
      stub(fn conn ->
        results =
          if conn.query_params["type"] == "page",
            do: [
              page_json(%{
                "version" => %{"number" => 2, "when" => "2026-10-02T12:00:00.000+02:00"}
              })
            ],
            else: []

        Req.Test.json(conn, %{"results" => results})
      end)

      assert {:ok, [page]} = HttpSource.pages("ENG", [])

      assert page.updated_at == ~U[2026-10-02 10:00:00.000Z]
    end

    test "fills in the defaults Confluence omits" do
      stub(fn conn ->
        results =
          if conn.query_params["type"] == "page", do: [%{"id" => 7, "_links" => %{}}], else: []

        Req.Test.json(conn, %{"results" => results})
      end)

      assert {:ok, [page]} = HttpSource.pages("ENG", [])

      assert page.title == "Untitled"
      assert page.type == "page"
      assert page.status == "current"
      assert page.ancestors == []
      assert page.parent_id == nil
      assert page.version == %{number: 1, message: nil, when: nil, by: %{}}
      assert page.url == nil
      assert page.created_at == nil
    end

    test "follows pagination links on the same host" do
      stub(fn conn ->
        case conn.query_params["start"] do
          nil ->
            # Only the page listing has a second page to follow.
            if conn.query_params["type"] == "page" do
              Req.Test.json(conn, %{
                "results" => [page_json(%{"id" => "1", "title" => "First"})],
                "_links" => %{"next" => "#{@base_url}/wiki/rest/api/content?start=50"}
              })
            else
              Req.Test.json(conn, %{"results" => []})
            end

          "50" ->
            Req.Test.json(conn, %{"results" => [page_json(%{"id" => "2", "title" => "Second"})]})
        end
      end)

      assert {:ok, [first, second]} = HttpSource.pages("ENG", [])
      assert {first.title, second.title} == {"First", "Second"}
    end

    test "refuses a pagination link that leaves the configured host" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "results" => [],
          "_links" => %{"next" => "https://evil.example/wiki/rest/api/content?start=50"}
        })
      end)

      assert {:error, :host_not_allowed} = HttpSource.pages("ENG", [])
    end
  end

  describe "page/2" do
    test "reads one page and takes the space from _expandable when it is not expanded" do
      stub(fn conn ->
        assert conn.request_path == "/wiki/rest/api/content/1002"

        Req.Test.json(
          conn,
          page_json(%{"space" => nil, "_expandable" => %{"space" => "/rest/api/space/ENG"}})
        )
      end)

      assert {:ok, page} = HttpSource.page(1002, [])
      assert page.space_key == "ENG"
    end
  end

  describe "comments/2 and attachments/2" do
    test "maps comments with their parent, version, export body and its own files" do
      # A comment can carry files, and they are found by asking the index for
      # everything whose container is one of this page's comments — one request
      # for the page rather than one per comment.
      stub(fn conn ->
        case conn.request_path do
          "/wiki/rest/api/content/1002/child/comment" ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "id" => "3001",
                  "ancestors" => [%{"id" => "2999"}],
                  "version" => %{
                    "number" => 2,
                    "when" => "2026-10-03T08:00:00.000Z",
                    "by" => %{"displayName" => "Sam", "accountId" => "acc-sam"}
                  },
                  "body" => %{"export_view" => %{"value" => "<p>nice</p>"}},
                  "_links" => %{"webui" => "/spaces/ENG/pages/1002?focusedCommentId=3001"}
                }
              ]
            })

          "/wiki/rest/api/content/search" ->
            Req.Test.json(conn, %{
              "results" => [comment_file_json("att9002", "shot.png", "3001")]
            })
        end
      end)

      assert {:ok, [comment]} = HttpSource.comments(1002, [])
      assert comment.id == 3001
      assert comment.page_id == 1002
      assert comment.parent_id == 2999
      assert comment.author == "Sam"
      assert comment.author_account_id == "acc-sam"
      assert comment.version_number == 2
      assert comment.body_export == "<p>nice</p>"
      assert comment.url =~ "focusedCommentId=3001"

      assert [file] = comment.attachments
      assert file.id == "att9002"
      assert file.filename == "shot.png"
      assert file.comment_id == 3001
    end

    test "a comment with no files costs no extra request" do
      stub(fn conn ->
        assert conn.request_path == "/wiki/rest/api/content/1002/child/comment"
        Req.Test.json(conn, %{"results" => []})
      end)

      assert {:ok, []} = HttpSource.comments(1002, [])
    end

    defp comment_file_json(id, filename, comment_id) do
      %{
        "id" => id,
        "title" => filename,
        "container" => %{"type" => "comment", "id" => comment_id},
        "version" => %{"number" => 1, "when" => "2026-10-03T08:00:00.000Z"},
        "extensions" => %{"mediaType" => "image/png", "fileSize" => 128},
        "_links" => %{"download" => "/download/attachments/#{comment_id}/#{filename}"}
      }
    end

    test "maps attachments with media type, size and download URL" do
      stub(fn conn ->
        assert conn.request_path == "/wiki/rest/api/content/1002/child/attachment"

        Req.Test.json(conn, %{
          "results" => [
            %{
              "id" => "9001",
              "title" => "diagram.svg",
              "extensions" => %{"mediaType" => "image/svg+xml", "fileSize" => 2048},
              "version" => %{"number" => 3},
              "_links" => %{"download" => "/wiki/download/attachments/1002/diagram.svg"}
            }
          ]
        })
      end)

      assert {:ok, [attachment]} = HttpSource.attachments(1002, [])
      assert attachment.filename == "diagram.svg"
      assert attachment.media_type == "image/svg+xml"
      assert attachment.byte_size == 2048
      assert attachment.version == 3
      assert attachment.download_url == "/wiki/download/attachments/1002/diagram.svg"
    end
  end

  describe "spaces/2 and restrictions/2" do
    test "maps a space with its description and homepage" do
      stub(fn conn ->
        assert conn.request_path == "/wiki/rest/api/space"

        Req.Test.json(conn, %{
          "results" => [
            %{
              "key" => "ENG",
              "name" => "Engineering Handbook",
              "description" => %{"plain" => %{"value" => "How we build."}},
              "homepage" => %{"id" => "1000"},
              "_links" => %{"webui" => "/spaces/ENG"}
            }
          ]
        })
      end)

      assert {:ok, [space]} = HttpSource.spaces([])
      assert space.key == "ENG"
      assert space.description == "How we build."
      assert space.homepage_id == 1000
      assert space.url == "#{@base_url}/wiki/spaces/ENG"
    end

    test "maps the space icon Confluence shows beside the name" do
      stub(fn conn ->
        assert conn.query_params["expand"] =~ "icon"

        Req.Test.json(conn, %{
          "results" => [
            %{
              "key" => "MFS",
              "name" => "My first space",
              "icon" => %{
                "path" => "/download/attachments/1/MFS-default",
                "width" => 48,
                "height" => 48,
                "isDefault" => false
              },
              "_links" => %{"webui" => "/spaces/MFS"}
            }
          ]
        })
      end)

      assert {:ok, [space]} = HttpSource.spaces([])
      assert space.icon == %{path: "/download/attachments/1/MFS-default"}
    end

    test "keeps the space's categories and drops content and reader labels" do
      stub(fn conn ->
        assert conn.query_params["expand"] =~ "metadata.labels"

        Req.Test.json(conn, %{
          "results" => [
            %{
              "key" => "MFS",
              "name" => "My first space",
              "metadata" => %{
                "labels" => %{
                  "results" => [
                    %{"prefix" => "my", "name" => "favourite"},
                    %{"prefix" => "team", "name" => "teams"},
                    %{"prefix" => "global", "name" => "api"}
                  ]
                }
              },
              "_links" => %{"webui" => "/spaces/MFS"}
            }
          ]
        })
      end)

      assert {:ok, [space]} = HttpSource.spaces([])
      assert space.labels == ["teams"]
    end

    test "a space that has no icon says so" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "results" => [%{"key" => "ENG", "name" => "Engineering", "icon" => nil}]
        })
      end)

      assert {:ok, [space]} = HttpSource.spaces([])
      assert space.icon == nil
    end

    test "reads the read restrictions of a page" do
      stub(fn conn ->
        assert conn.request_path == "/wiki/rest/api/content/1002/restriction/byOperation/read"

        Req.Test.json(conn, %{
          "restrictions" => %{
            "user" => %{"results" => [%{"email" => "jane@acme.test"}]},
            "group" => %{"results" => [%{"name" => "engineering"}]}
          }
        })
      end)

      assert {:ok, restrictions} = HttpSource.restrictions(1002, [])

      assert restrictions == [
               %{subject_type: "user", subject_key: "jane@acme.test"},
               %{subject_type: "group", subject_key: "engineering"}
             ]
    end
  end

  describe "changed_since/2" do
    test "asks for recent content and keeps only the configured spaces" do
      put_config(spaces: ["ENG"])

      stub(fn conn ->
        assert conn.request_path == "/wiki/rest/api/content/search"
        assert conn.query_params["cql"] =~ ~s[lastmodified >= "2026-10-01 12:34"]

        Req.Test.json(conn, %{
          "results" => [
            page_json(%{"id" => "1", "space" => %{"key" => "ENG"}}),
            page_json(%{"id" => "2", "space" => %{"key" => "PROD"}})
          ]
        })
      end)

      assert {:ok, [page]} = HttpSource.changed_since(~U[2026-10-01 12:34:56Z], [])
      assert page.space_key == "ENG"
    end
  end

  describe "request handling" do
    test "sends the configured API credentials" do
      stub(fn conn ->
        send(self(), {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"results" => []})
      end)

      assert {:ok, []} = HttpSource.pages("ENG", [])

      expected = "Basic " <> Base.encode64("mirror@acme.test:secret-token")
      assert_receive {:auth, [^expected]}
    end

    test "uses a bearer token when only a token is configured" do
      put_config(email: nil)

      stub(fn conn ->
        send(self(), {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"results" => []})
      end)

      assert {:ok, []} = HttpSource.pages("ENG", [])
      assert_receive {:auth, ["Bearer secret-token"]}
    end

    test "retries a 429 before giving up" do
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
      assert Process.get(:attempt) == 1
    end

    test "a 429 that names a wait is obeyed, not raced with our own backoff" do
      stub(fn conn ->
        case Process.get(:attempt, 0) do
          0 ->
            Process.put(:attempt, 1)
            conn |> Plug.Conn.put_resp_header("retry-after", "1") |> Plug.Conn.resp(429, "")

          _ ->
            Req.Test.json(conn, %{"results" => []})
        end
      end)

      {elapsed_us, result} = :timer.tc(fn -> HttpSource.pages("ENG", []) end)

      assert {:ok, []} = result
      # The configured backoff is 0 in these tests, so only the header can
      # account for the pause.
      assert elapsed_us >= 900_000
    end

    test "a 429 asking for an hour is not slept through inside the request" do
      stub(fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "3600") |> Plug.Conn.resp(429, "")
      end)

      {elapsed_us, result} = :timer.tc(fn -> HttpSource.pages("ENG", []) end)

      # The number goes to the caller, and the call returns at once: a run that
      # waits is a run nobody can see, and this one ran for an hour like that.
      assert {:error, {:throttled, 3600}} = result
      assert elapsed_us < 1_000_000
    end

    test "reports an error when every attempt fails" do
      stub(fn conn -> Plug.Conn.resp(conn, 503, "maintenance") end)

      assert {:error, {:http, 503, "maintenance"}} = HttpSource.pages("ENG", [])
    end

    test "treats 401, 403 and 404 as their own outcomes" do
      stub(fn conn -> Plug.Conn.resp(conn, 401, "bad token") end)
      assert {:error, {:unauthorized, "bad token"}} = HttpSource.pages("ENG", [])

      stub(fn conn -> Plug.Conn.resp(conn, 403, "no access") end)
      assert {:error, {:forbidden, "no access"}} = HttpSource.pages("ENG", [])

      stub(fn conn -> Plug.Conn.resp(conn, 404, "gone") end)
      assert {:error, :not_found} = HttpSource.pages("ENG", [])
    end

    test "reports invalid JSON instead of crashing" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{not json")
      end)

      assert {:error, :invalid_json} = HttpSource.pages("ENG", [])
    end

    test "refuses a JSON body above the configured cap" do
      put_config(max_json_bytes: 32)

      stub(fn conn -> Req.Test.json(conn, %{"results" => [page_json()]}) end)

      assert {:error, {:body_too_large, size, 32}} = HttpSource.pages("ENG", [])
      assert size > 32
    end

    test "reports transport failures after the last attempt" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:transport, _reason}} = HttpSource.pages("ENG", [])
    end
  end

  describe "space_icon/2" do
    # Confluence's web icon path answers a browser session, not an API token, so
    # the client asks for the REST attachment link and downloads that instead.
    test "translates the web icon path into the REST link that accepts a token" do
      stub(fn
        %Plug.Conn{request_path: "/wiki/rest/api/content/1/child/attachment"} = conn ->
          assert conn.query_params["filename"] == "MFS-default"

          Req.Test.json(conn, %{
            "results" => [
              %{"_links" => %{"download" => "/rest/api/content/1/child/attachment/att9/download"}}
            ]
          })

        %Plug.Conn{request_path: "/wiki/rest/api/content/1/child/attachment/att9/download"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "image/png; charset=binary")
          |> Plug.Conn.resp(200, "png-bytes")
      end)

      assert {:ok, %{body: "png-bytes", media_type: "image/png"}} =
               HttpSource.space_icon(%{path: "/download/attachments/1/MFS-default?version=2"}, [])
    end

    test "a personal space's icon is the owner's avatar, fetched as published" do
      stub(fn conn ->
        assert conn.request_path == "/wiki/aa-avatar/557058:12861f68"
        Plug.Conn.resp(conn, 200, "avatar-bytes")
      end)

      assert {:ok, %{body: "avatar-bytes"}} =
               HttpSource.space_icon(%{path: "/aa-avatar/557058:12861f68"}, [])
    end

    test "reports an icon the space no longer carries" do
      stub(fn conn -> Req.Test.json(conn, %{"results" => []}) end)

      assert {:error, :icon_not_found} =
               HttpSource.space_icon(%{path: "/download/attachments/1/gone"}, [])
    end

    test "reports a download the site will not serve" do
      stub(fn
        %Plug.Conn{request_path: "/wiki/rest/api/content/1/child/attachment"} = conn ->
          Req.Test.json(conn, %{
            "results" => [
              %{"_links" => %{"download" => "/rest/api/content/1/child/attachment/att9/download"}}
            ]
          })

        %Plug.Conn{} = conn ->
          Plug.Conn.resp(conn, 404, "gone")
      end)

      assert {:error, {:http, 404}} =
               HttpSource.space_icon(%{path: "/download/attachments/1/gone"}, [])
    end
  end

  describe "attachment_data/2" do
    test "returns the bytes of a mirrored attachment" do
      stub(fn conn ->
        assert conn.request_path == "/wiki/download/attachments/1002/diagram.svg"
        Plug.Conn.resp(conn, 200, "<svg/>")
      end)

      attachment = %{download_url: "/wiki/download/attachments/1002/diagram.svg"}
      assert {:ok, "<svg/>"} = HttpSource.attachment_data(attachment, [])
    end

    test "reports a missing attachment" do
      stub(fn conn -> Plug.Conn.resp(conn, 404, "gone") end)

      attachment = %{download_url: "/wiki/download/attachments/1002/gone.svg"}
      assert {:error, {:http, 404}} = HttpSource.attachment_data(attachment, [])
    end

    test "follows the redirect Cloud puts in front of the media API" do
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
    end

    test "refuses to follow a redirect off the allowed hosts" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.example/steal")
        |> Plug.Conn.resp(302, "")
      end)

      attachment = %{download_url: "/wiki/download/attachments/1002/diagram.svg"}

      assert {:error, {:redirect_not_allowed, ["https://evil.example/steal"]}} =
               HttpSource.attachment_data(attachment, [])
    end
  end

  describe "touched_since/2" do
    # A child's version does not bump its page's, so a window over pages alone
    # never sees a new comment or file. The search index answers with the child
    # and its container, and the answer has to end up as "these pages to read
    # again".
    test "answers which pages the changed children belong to" do
      test_process = self()

      stub(fn conn ->
        send(test_process, {:requested, conn.request_path})

        case conn.request_path do
          "/wiki/rest/api/content/search" ->
            Req.Test.json(conn, %{
              "results" => [
                comment_on_page("2001", "1002"),
                file_in_comment("att7001", "2001"),
                file_in_comment("att7002", "9306117"),
                file_in_a_space("att7003")
              ]
            })

          "/wiki/rest/api/content/9306117" ->
            Req.Test.json(conn, %{
              "id" => "9306117",
              "container" => %{"type" => "page", "id" => "4456832"}
            })
        end
      end)

      assert {:ok, %{pages: pages, space_attachments: 1}} =
               HttpSource.touched_since(~U[2026-10-20 00:00:00Z], [])

      assert pages == [1002, 4_456_832]

      # The comment in the window already names its page, so its files cost no
      # request; the comment outside the window is the one that has to be asked.
      assert_received {:requested, "/wiki/rest/api/content/9306117"}
      refute_received {:requested, "/wiki/rest/api/content/2001"}
    end

    # A run that cannot place a child must say so: a file quietly dropped is a
    # page whose screenshot never updates again.
    test "content whose owner cannot be placed is an error, not a silent skip" do
      for {result, reason} <- [
            {%{"id" => "att7004", "container" => %{"type" => "attachment", "id" => "5"}},
             {:unexpected_container, "attachment"}},
            {%{"id" => "att7005"}, :no_container}
          ] do
        stub(fn conn -> Req.Test.json(conn, %{"results" => [result]}) end)

        assert {:error, {:unresolved_owner, id, ^reason}} = HttpSource.touched_since(nil, [])
        assert id == result["id"]
      end
    end

    defp comment_on_page(comment_id, page_id) do
      %{
        "id" => comment_id,
        "type" => "comment",
        "container" => %{"type" => "page", "id" => page_id}
      }
    end

    defp file_in_comment(attachment_id, comment_id) do
      %{
        "id" => attachment_id,
        "type" => "attachment",
        "container" => %{"type" => "comment", "id" => comment_id}
      }
    end

    defp file_in_a_space(attachment_id) do
      %{
        "id" => attachment_id,
        "type" => "attachment",
        "container" => %{"type" => "global", "id" => "9470147"}
      }
    end
  end

  describe "group membership" do
    # Cloud no longer answers "who is in this group"; it answers this instead,
    # so a live sync learns membership one person at a time.
    test "the site is asked which groups one account belongs to" do
      stub(fn conn ->
        assert conn.request_path == "/wiki/rest/api/user/memberof"
        assert conn.query_params["accountId"] == "557058:jane"

        Req.Test.json(conn, %{
          "results" => [%{"name" => "confluence-users"}, %{"name" => "confluence-admins"}]
        })
      end)

      assert {:ok, ["confluence-users", "confluence-admins"]} =
               HttpSource.groups_of_account("557058:jane", [])
    end
  end
end
