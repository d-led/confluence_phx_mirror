defmodule ConfluencePhxMirror.Confluence.HttpSourceTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Confluence.HttpSource

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
end
