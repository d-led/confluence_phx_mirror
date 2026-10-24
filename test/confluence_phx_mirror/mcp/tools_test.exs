defmodule ConfluencePhxMirror.Mcp.ToolsTest do
  @moduledoc """
  What each tool answers, and — just as important — what it leaves out.

  The demo snapshot has one page restricted to `confluence-users`, and these
  tests read as an anonymous reader throughout: that is the case where a leak
  would show. The companion file `mcp_protocol_test.exs` proves an API token
  and a proxy identity reach the same functions through HTTP.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mcp.Tools

  setup do
    demo_snapshot!()
    # A reader nobody has admitted and no group names: anonymous.
    {:ok, scope: Scope.for_user(nil)}
  end

  describe "search" do
    test "a text query finds a page and says where it is", %{scope: scope} do
      {:ok, %{text: text, structured: %{"results" => results}}} =
        call("confluence_search", %{"query" => "architecture"}, scope)

      assert text =~ "Architecture Overview"
      assert Enum.any?(results, &(&1["title"] == "Architecture Overview"))
      assert Enum.all?(results, &String.starts_with?(&1["url"], "http"))
    end

    test "CQL is understood when the query looks like CQL", %{scope: scope} do
      {:ok, %{structured: %{"results" => results}}} =
        call("confluence_search", %{"query" => "space = ENG AND label = architecture"}, scope)

      assert Enum.map(results, & &1["title"]) == ["Architecture Overview"]
    end

    test "a broken CQL expression is still searched as words", %{scope: scope} do
      assert {:ok, %{text: _text}} =
               call("confluence_search", %{"query" => "= AND ="}, scope)
    end

    test "the advanced search takes the UI's filters", %{scope: scope} do
      {:ok, %{structured: %{"results" => results}}} =
        call("confluence_advanced_search", %{"label" => "architecture", "type" => "page"}, scope)

      assert Enum.map(results, & &1["title"]) == ["Architecture Overview"]
    end

    test "the advanced search refuses to guess when every filter is blank", %{scope: scope} do
      assert {:error, message} = call("confluence_advanced_search", %{}, scope)
      assert message =~ "Provide"
    end

    test "a restricted page does not come back as a hit", %{scope: scope} do
      {:ok, %{structured: %{"results" => results}}} =
        call("confluence_search", %{"query" => Demo.restricted_page_title()}, scope)

      refute Enum.any?(results, &(&1["title"] == Demo.restricted_page_title()))
    end
  end

  describe "reading a page" do
    test "Markdown is the default, with a header that names the page", %{scope: scope} do
      {:ok, %{text: text, structured: structured}} =
        call("confluence_get_page", %{"page_id" => Demo.open_page()}, scope)

      assert text =~ "# Architecture Overview"
      assert text =~ "- id: 1002"
      assert text =~ "- space: ENG — Engineering Handbook"
      assert text =~ "diagram.svg"
      assert structured["format"] == "markdown"
      assert structured["url"] =~ "/spaces/ENG/pages/1002"
    end

    test "metadata can be left out", %{scope: scope} do
      {:ok, %{text: text}} =
        call(
          "confluence_get_page",
          %{"page_id" => Demo.open_page(), "include_metadata" => false},
          scope
        )

      assert text =~ "# Architecture Overview"
      refute text =~ "- id: 1002"
    end

    test "storage format is there for callers that need the macros", %{scope: scope} do
      {:ok, %{text: text, structured: structured}} =
        call(
          "confluence_get_page",
          %{"page_id" => Demo.open_page(), "convert_to_markdown" => false},
          scope
        )

      assert text =~ "<"
      assert structured["format"] == "storage"
    end

    test "a page can also be named by its title and space", %{scope: scope} do
      {:ok, %{structured: structured}} =
        call(
          "confluence_get_page",
          %{"title" => Demo.open_page_title(), "space_key" => "eng"},
          scope
        )

      assert structured["id"] == Demo.open_page()
    end

    test "a page can be named by the URL a person would paste", %{scope: scope} do
      url = "https://acme.atlassian.net/wiki/spaces/ENG/pages/1002/Architecture+Overview"

      assert {:ok, %{structured: %{"id" => "1002"}}} =
               call("confluence_get_page", %{"page_id" => url}, scope)
    end

    test "an unknown page is reported as not mirrored", %{scope: scope} do
      assert {:error, "Page 999999 is not mirrored."} =
               call("confluence_get_page", %{"page_id" => "999999"}, scope)
    end

    test "a restricted page is reported the same way as an unknown one", %{scope: scope} do
      assert {:error, "Page 1003 is not mirrored."} =
               call("confluence_get_page", %{"page_id" => Demo.restricted_page()}, scope)
    end

    test "a call without a page reference says what to provide", %{scope: scope} do
      assert {:error, message} = call("confluence_get_page", %{}, scope)
      assert message =~ "`title`"
      assert message =~ "`page_id`"
    end
  end

  describe "walking the hierarchy" do
    test "children are listed by title, and restricted ones are not listed at all", %{
      scope: scope
    } do
      {:ok, %{text: text, structured: %{"children" => children}}} =
        call("confluence_get_page_children", %{"parent_id" => "1001"}, scope)

      assert Enum.map(children, & &1["title"]) == ["Architecture Overview"]
      assert text =~ "Architecture Overview"
      refute text =~ Demo.restricted_page_title()
    end

    test "children can carry their bodies when that is what the caller needs", %{scope: scope} do
      {:ok, %{text: text}} =
        call(
          "confluence_get_page_children",
          %{"parent_id" => "1001", "include_content" => true},
          scope
        )

      assert text =~ "## Architecture Overview"
      assert text =~ "poll → render"
    end

    test "ancestors come root first", %{scope: scope} do
      {:ok, %{text: text, structured: %{"ancestors" => ancestors}}} =
        call("confluence_get_page_ancestors", %{"page_id" => Demo.open_page()}, scope)

      assert Enum.map(ancestors, & &1["title"]) == ["Engineering Handbook", "Getting Started"]
      assert text =~ ~r/1\. Engineering Handbook.*2\. Getting Started/s
    end

    test "a space's tree is indented by depth", %{scope: scope} do
      {:ok, %{text: text, structured: structured}} =
        call("confluence_get_space_page_tree", %{"space_key" => "eng"}, scope)

      assert text =~ "- Engineering Handbook (id 1000)"
      assert text =~ "\n  - Getting Started (id 1001)"
      assert text =~ "\n    - Architecture Overview (id 1002)"

      getting_started = Enum.find(structured["pages"], &(&1["id"] == "1001"))
      assert getting_started["depth"] == 1
    end

    test "the tree leaves out a page the reader may not open", %{scope: scope} do
      {:ok, %{text: text, structured: structured}} =
        call("confluence_get_space_page_tree", %{"space_key" => "ENG"}, scope)

      refute text =~ Demo.restricted_page_title()
      refute Enum.any?(structured["pages"], &(&1["id"] == Demo.restricted_page()))
    end

    test "backlinks are filtered too", %{scope: scope} do
      {:ok, %{text: text, structured: %{"backlinks" => backlinks}}} =
        call("confluence_get_backlinks", %{"page_id" => Demo.open_page()}, scope)

      assert Enum.any?(backlinks, &(&1["title"] == "Getting Started"))
      refute Enum.any?(backlinks, &(&1["title"] == Demo.restricted_page_title()))
      assert text =~ "Getting Started"
    end
  end

  describe "the material around a page" do
    test "comments keep their author, time and thread", %{scope: scope} do
      {:ok, %{text: text, structured: %{"comments" => comments}}} =
        call("confluence_get_comments", %{"page_id" => "1001"}, scope)

      assert length(comments) == 2
      assert text =~ "Sam Rivera"
      assert text =~ "Jane Doe"
      assert text =~ "Reply in thread 3001."
      assert text =~ "*Contractors*"
    end

    test "labels are listed with the catalogue entry for each", %{scope: scope} do
      {:ok, %{text: text, structured: %{"labels" => labels}}} =
        call("confluence_get_labels", %{"page_id" => Demo.open_page()}, scope)

      assert Enum.map(labels, & &1["name"]) == ["architecture", "design"]
      assert text =~ "architecture, design"
      assert hd(labels)["url"] =~ "/labels/architecture"
    end

    test "attachments are named, sized and linked", %{scope: scope} do
      {:ok, %{text: text, structured: %{"attachments" => files}}} =
        call("confluence_get_attachments", %{"page_id" => "1005"}, scope)

      notes = Enum.find(files, &(&1["filename"] == "notes.md"))
      assert notes["media_type"] == "text/markdown"
      assert notes["url"] =~ "/attachments/ENG/1005/"
      assert text =~ "notes.md"
    end
  end

  describe "spaces" do
    test "the space list is the reader's directory: a private space is not in it", %{scope: scope} do
      {:ok, %{text: text, structured: %{"spaces" => spaces}}} =
        call("confluence_list_spaces", %{}, scope)

      assert Enum.map(spaces, & &1["key"]) == ["ENG"]
      assert text =~ "ENG — Engineering Handbook"
      refute text =~ "Product Hub"
    end

    test "a signed-in reader sees the spaces the site opens to members" do
      {:ok, %{structured: %{"spaces" => spaces}}} =
        call("confluence_list_spaces", %{}, reader_scope())

      assert Enum.map(spaces, & &1["key"]) == ["ENG", "PROD"]
    end

    test "a private space says it is not mirrored to a reader outside it", %{scope: scope} do
      assert {:error, "Space PROD is not mirrored."} =
               call("confluence_get_space", %{"space_key" => "PROD"}, scope)
    end

    test "a space describes itself, its home page and how much is readable", %{scope: scope} do
      {:ok, %{text: text, structured: structured}} =
        call("confluence_get_space", %{"space_key" => "eng"}, scope)

      assert text =~ "# Engineering Handbook (ENG)"
      assert text =~ "- home page: Engineering Handbook (id 1000)"
      assert structured["pages"] > 0
      assert structured["labels"] == ["platform"]
    end

    test "a space that is not mirrored says so", %{scope: scope} do
      assert {:error, "Space NOPE is not mirrored."} =
               call("confluence_get_space", %{"space_key" => "nope"}, scope)
    end

    test "blog posts come newest first" do
      {:ok, %{text: text, structured: %{"posts" => posts}}} =
        call("confluence_list_blog_posts", %{"space_key" => "PROD"}, reader_scope())

      assert Enum.map(posts, & &1["title"]) == ["Release 2.0"]
      assert text =~ "by Priya Nair"
    end

    test "recent changes answer across the mirror or within one space", %{scope: scope} do
      {:ok, %{structured: %{"changes" => everywhere}}} =
        call("confluence_get_recent_changes", %{"limit" => 3}, scope)

      assert Enum.any?(everywhere, &(&1["title"] == "Meeting Notes"))

      {:ok, %{structured: %{"changes" => product}}} =
        call("confluence_get_recent_changes", %{"space_key" => "PROD"}, reader_scope())

      assert Enum.all?(product, &(&1["space"] == "PROD"))
    end
  end

  describe "index status" do
    test "an administrator sees what was indexed last" do
      scope = Scope.for_user(user_fixture(%{email: "mcp-admin@example.com", role: "admin"}))

      {:ok, %{text: text, structured: structured}} =
        call("confluence_index_status", %{}, scope)

      assert text =~ "Recent sync runs"
      assert text =~ "Spaces, most recently indexed first"
      assert text =~ "ENG"
      assert structured["last_successful"]["status"] == "succeeded"
      assert Enum.any?(structured["spaces"], &(&1["key"] == "ENG"))
      assert structured["totals"]["pages"] > 0
    end

    test "one space can be asked about on its own" do
      scope = Scope.for_user(user_fixture(%{email: "mcp-admin-2@example.com", role: "admin"}))

      {:ok, %{structured: %{"spaces" => spaces}}} =
        call("confluence_index_status", %{"space_key" => "ENG"}, scope)

      assert Enum.map(spaces, & &1["key"]) == ["ENG"]
    end

    test "a reader who is not an administrator is refused", %{scope: scope} do
      assert {:error, message} = call("confluence_index_status", %{}, scope)
      assert message == "Only mirror administrators can read the index status."
    end
  end

  # A reader the demo site admits (it opens `PROD` to authenticated members) but
  # no group names: the case between an anonymous visitor and an administrator.
  defp reader_scope do
    user = user_fixture(%{email: "tools-reader@example.com"})
    Scope.for_user(user)
  end

  defp call(name, arguments, scope), do: Tools.call(name, arguments, scope)
end
