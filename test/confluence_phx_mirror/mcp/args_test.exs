defmodule ConfluencePhxMirror.Mcp.ArgsTest do
  @moduledoc """
  The request-parsing layer: how a tool call's JSON becomes typed arguments, and
  how a page is named. Pure functions, so no database and no connection.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mcp.{Args, PageRef}

  describe "Args" do
    test "a required string is trimmed and a blank one is an error" do
      assert Args.required(%{"query" => "  rate limit  "}, "query") == {:ok, "rate limit"}
      assert {:error, message} = Args.required(%{"query" => "   "}, "query")
      assert message =~ "`query` is required"
    end

    test "a number is accepted where a string is expected, because clients send both" do
      assert Args.required(%{"page_id" => 1002}, "page_id") == {:ok, "1002"}
    end

    test "an integer argument is clamped to the tool's range rather than refused" do
      assert Args.integer(%{"limit" => 500}, "limit", default: 10, max: 50) == {:ok, 50}
      assert Args.integer(%{"limit" => "3"}, "limit", default: 10, max: 50) == {:ok, 3}
      assert Args.integer(%{}, "limit", default: 10, max: 50) == {:ok, 10}
      assert {:error, message} = Args.integer(%{"limit" => "lots"}, "limit", default: 10)
      assert message =~ "`limit` must be an integer"
    end

    test "a boolean accepts the two strings a form-encoded client sends" do
      assert Args.boolean(%{"convert_to_markdown" => "false"}, "convert_to_markdown", true) ==
               {:ok, false}

      assert Args.boolean(%{}, "convert_to_markdown", true) == {:ok, true}
      assert {:error, _message} = Args.boolean(%{"flag" => "maybe"}, "flag", true)
    end

    test "one of a fixed set is checked, with a message that lists the set" do
      assert Args.one_of(%{"sort" => "newest"}, "sort", ~w(relevance newest), "relevance") ==
               {:ok, "newest"}

      assert {:error, message} =
               Args.one_of(%{"sort" => "sideways"}, "sort", ~w(relevance), "relevance")

      assert message =~ "relevance"
    end
  end

  describe "PageRef" do
    test "a bare id is an id" do
      assert PageRef.parse("1002") == {:ok, {:id, 1002}}
      assert PageRef.parse(1002) == {:ok, {:id, 1002}}
    end

    test "a page URL carries the id the mirror serves it by" do
      url = "https://acme.atlassian.net/wiki/spaces/ENG/pages/1002/Architecture+Overview"

      assert PageRef.parse(url) == {:ok, {:id, 1002}}
    end

    test "the old view page shape is read too" do
      assert PageRef.parse("https://acme.atlassian.net/wiki/pages/viewpage.action?pageId=1002") ==
               {:ok, {:id, 1002}}

      assert PageRef.parse(
               "https://acme.atlassian.net/wiki/pages/viewpage.action?spaceKey=ENG&pageId=7"
             ) ==
               {:ok, {:id, 7}}
    end

    test "a tiny link cannot be resolved without the site, and says so" do
      assert PageRef.parse("https://acme.atlassian.net/wiki/x/N4CIO") == :error
      assert PageRef.parse("Architecture Overview") == :error
    end
  end
end
