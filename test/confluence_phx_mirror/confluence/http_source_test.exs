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
end
