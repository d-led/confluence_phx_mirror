defmodule ConfluencePhxMirrorWeb.McpPageController do
  @moduledoc """
  The page a person lands on when they want an assistant to read the mirror.

  Three ways in, in the order most people want them: this mirror's own MCP server
  (nothing to install), sooperset's `mcp-atlassian` pointed at this mirror (it
  speaks Confluence's REST API, which this mirror answers), and the VS Code block
  that starts either one.

  The URLs are the ones the request arrived on. A mirror behind a proxy has no
  other way to know its own name, and a copy-paste block with the wrong host in it
  is worse than no block.
  """

  use ConfluencePhxMirrorWeb, :controller

  def show(conn, _params) do
    render(conn, :show,
      page_title: "MCP",
      mcp_url: url(~p"/api/mcp"),
      confluence_url: url(~p"/wiki")
    )
  end
end
