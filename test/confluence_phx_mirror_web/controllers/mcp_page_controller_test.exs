defmodule ConfluencePhxMirrorWeb.McpPageControllerTest do
  @moduledoc """
  The page exists to be copied from, so what it says is the behaviour: the
  endpoint of *this* mirror, and sooperset's server given that same site.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  describe "GET /mcp" do
    setup %{conn: conn} do
      {:ok, conn: log_in_admin(conn)}
    end

    test "names the mirror's own MCP endpoint, on the host the request came to", %{
      conn: conn
    } do
      assert text_of(conn, "#mcp-option-1 code") == mirror_address() <> "/api/mcp"
    end

    test "points sooperset's server at this mirror, not at Confluence", %{conn: conn} do
      block = text_of(conn, "#mcp-option-2")

      assert block =~ "CONFLUENCE_URL=#{mirror_address()}/wiki"
      assert block =~ "uvx mcp-atlassian"
    end

    test "offers a VS Code file that starts either server", %{conn: conn} do
      block = text_of(conn, "#mcp-option-3 code")

      assert block =~ ~s{"type": "http"}
      assert block =~ ~s{"command": "uvx"}
    end
  end

  test "the footer links to it from every reader page", %{conn: conn} do
    document =
      conn |> log_in_admin() |> get(~p"/mcp") |> html_response(200) |> LazyHTML.from_fragment()

    assert [link] = document |> LazyHTML.query(~s(footer a[href="/mcp"])) |> Enum.to_list()
    assert LazyHTML.text(link) == "MCP"
  end

  # A mirror behind a proxy cannot know its own name any other way, so the page
  # must say what the request was addressed to.
  defp mirror_address do
    ConfluencePhxMirrorWeb.Endpoint.url()
  end

  defp text_of(conn, selector) do
    document = conn |> get(~p"/mcp") |> html_response(200) |> LazyHTML.from_fragment()

    [node] = document |> LazyHTML.query(selector) |> Enum.to_list()
    LazyHTML.text(node)
  end
end
