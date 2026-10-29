defmodule ConfluencePhxMirror.Confluence.HttpSourceTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Confluence.HttpSource

  describe "parsing a page" do
    test "a live doc keeps the kind Confluence gives it" do
      assert HttpSource.parse_page(content(%{"subtype" => "live"}), "ENG").subtype == "live"
    end

    test "an ordinary page has no kind" do
      assert HttpSource.parse_page(content(%{}), "ENG").subtype == nil
    end

    defp content(overrides) do
      Map.merge(
        %{
          "id" => "458759",
          "type" => "page",
          "status" => "current",
          "title" => "Meeting notes",
          "version" => %{"number" => 1},
          "ancestors" => [],
          "metadata" => %{"labels" => %{"results" => []}},
          "_links" => %{"webui" => "/spaces/ENG/pages/458759"}
        },
        overrides
      )
    end
  end

  describe "parsing page restrictions" do
    test "reads users by e-mail and groups by name" do
      body = %{
        "operation" => "read",
        "restrictions" => %{
          "user" => %{"results" => [%{"email" => "jane@acme.com"}]},
          "group" => %{"results" => [%{"name" => "confluence-users"}]}
        }
      }

      assert HttpSource.parse_restrictions(body) == [
               %{subject_type: "user", subject_key: "jane@acme.com"},
               %{subject_type: "group", subject_key: "confluence-users"}
             ]
    end

    test "falls back to the account id when Confluence hides the e-mail" do
      body = %{"restrictions" => %{"user" => %{"results" => [%{"accountId" => "acc-1"}]}}}

      assert HttpSource.parse_restrictions(body) == [
               %{subject_type: "user", subject_key: "acc-1"}
             ]
    end

    test "an unrestricted page has no subjects" do
      assert HttpSource.parse_restrictions(%{"operation" => "read"}) == []
    end
  end

  describe "parsing space permissions" do
    test "a read grant names the people, the group and the anonymous reader" do
      body = %{
        "permissions" => [
          %{
            "operation" => %{"operation" => "read", "targetType" => "space"},
            "anonymousAccess" => true,
            "subjects" => %{
              "user" => %{"results" => [%{"accountId" => "acc-1", "email" => "jane@acme.com"}]},
              "group" => %{"results" => [%{"name" => "confluence-users", "id" => "g-1"}]}
            }
          }
        ]
      }

      assert HttpSource.parse_space_permissions(body) == [
               %{operation: "read", subject_type: "anonymous", subject_key: nil},
               %{operation: "read", subject_type: "user", subject_key: "acc-1"},
               %{operation: "read", subject_type: "user", subject_key: "jane@acme.com"},
               %{operation: "read", subject_type: "group", subject_key: "confluence-users"}
             ]
    end

    test "grants for anything but reading are not who may read" do
      body = %{
        "permissions" => [
          %{
            "operation" => %{"operation" => "administer"},
            "subjects" => %{
              "user" => %{"results" => [%{"accountId" => "acc-admin"}]}
            }
          },
          %{
            "operation" => %{"operation" => "read"},
            "subjects" => %{
              "user" => %{"results" => [%{"accountId" => "acc-reader"}]}
            }
          }
        ]
      }

      assert HttpSource.parse_space_permissions(body) == [
               %{operation: "read", subject_type: "user", subject_key: "acc-reader"}
             ]
    end

    test "a group is matched the way Confluence matches it, without case" do
      body = %{
        "permissions" => [
          %{
            "operation" => %{"operation" => "read"},
            "subjects" => %{"group" => %{"results" => [%{"name" => "Confluence-Users"}]}}
          }
        ]
      }

      assert [%{subject_key: "confluence-users"}] = HttpSource.parse_space_permissions(body)
    end

    test "a space that answers without permissions grants nothing listable" do
      assert HttpSource.parse_space_permissions(%{"key" => "ENG"}) == []
      assert HttpSource.parse_space_permissions(%{"permissions" => []}) == []
    end
  end

  describe "who owns a change the page window cannot see" do
    test "a comment belongs to its page" do
      # Observed on a real site: a comment's container is the page.
      result = %{
        "id" => "9306117",
        "type" => "comment",
        "container" => %{"type" => "page", "id" => "4456832"}
      }

      assert HttpSource.owner_of(result) == {:page, 4_456_832}
    end

    test "a file pasted into a comment belongs to the comment" do
      # Also observed: the file's container is the comment, not the page, so the
      # comment's own container is what has to be asked for.
      result = %{
        "id" => "att9306121",
        "type" => "attachment",
        "container" => %{"type" => "comment", "id" => "9306117"}
      }

      assert HttpSource.owner_of(result) == {:comment, 9_306_117}
    end

    test "a file a space keeps for its own layout belongs to no page" do
      result = %{"id" => "att9470239", "container" => %{"type" => "global", "id" => "9470147"}}

      assert HttpSource.owner_of(result) == :space
    end

    test "a container the mirror does not model is named, not guessed" do
      assert HttpSource.owner_of(%{"container" => %{"type" => "attachment"}}) ==
               {:unexpected, "attachment"}
    end
  end

  describe "parsing a comment" do
    test "reads the version it was written at and the date it was last edited" do
      content = %{
        "id" => "9306117",
        "body" => %{"export_view" => %{"value" => "<p>Looks good</p>"}},
        "version" => %{
          "number" => 2,
          "when" => "2026-10-23T21:35:53.763Z",
          "by" => %{"displayName" => "Jane", "accountId" => "acc-1"}
        },
        "history" => %{"createdDate" => "2026-10-23T20:00:00.000Z"},
        "ancestors" => [%{"id" => "4456832"}],
        "_links" => %{}
      }

      comment = HttpSource.parse_comment(content, 4_456_832)

      assert comment.version_number == 2
      assert comment.author_account_id == "acc-1"
      assert comment.updated_at == ~U[2026-10-23 21:35:53.763Z]
      assert comment.created_at == ~U[2026-10-23 20:00:00.000Z]
    end

    test "groups a page's files by the comment that owns them" do
      results = [
        comment_file("att1", "one.png", "700"),
        comment_file("att2", "two.png", "700"),
        comment_file("att3", "three.png", "701")
      ]

      files = HttpSource.group_comment_files(results, 4_456_832)

      assert files |> Map.keys() |> Enum.sort() == [700, 701]
      assert files[700] |> Enum.map(& &1.filename) == ["one.png", "two.png"]
      assert Enum.all?(files[700], &(&1.comment_id == 700))
      assert Enum.all?(files[700], &(&1.page_id == 4_456_832))
    end

    defp comment_file(id, filename, comment_id) do
      %{
        "id" => id,
        "title" => filename,
        "container" => %{"type" => "comment", "id" => comment_id},
        "version" => %{"number" => 1, "when" => "2026-10-23T21:00:00.000Z"},
        "extensions" => %{"mediaType" => "image/png", "fileSize" => 42},
        "_links" => %{"download" => "/download/attachments/#{comment_id}/#{filename}"}
      }
    end
  end
end
