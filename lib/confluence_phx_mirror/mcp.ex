defmodule ConfluencePhxMirror.Mcp do
  @moduledoc """
  The Model Context Protocol server's identity: protocol versions, its name,
  and the instructions a client receives on `initialize`.

  The transport lives in `ConfluencePhxMirrorWeb.Mcp.Protocol` and
  `ConfluencePhxMirrorWeb.McpController`; the tools in `ConfluencePhxMirror.Mcp.Tools`
  and the modules below it. This module holds the parts every one of them
  agrees on, so a version is named once.

  The server is read-only by design: a mirror's content changes only through
  `ConfluencePhxMirror.Sync`, and an assistant asking questions should not be
  able to rewrite somebody's wiki through it.
  """

  alias ConfluencePhxMirror.Sites

  # Newest first. `initialize` answers with what the client asked for when the
  # mirror speaks it and with the first entry when it does not, which is what
  # the lifecycle section of the specification asks a server to do.
  @protocol_versions ~w(2025-06-18 2025-03-26 2024-11-05)

  @doc "Protocol revisions this server can talk."
  @spec protocol_versions() :: [String.t()]
  def protocol_versions, do: @protocol_versions

  @doc "The newest revision, used when the client asks for one we do not know."
  @spec latest_protocol_version() :: String.t()
  def latest_protocol_version, do: hd(@protocol_versions)

  @doc "Whether the mirror speaks this revision."
  @spec protocol_version?(term()) :: boolean()
  def protocol_version?(version) when is_binary(version), do: version in @protocol_versions
  def protocol_version?(_version), do: false

  @doc """
  The revision to answer an `initialize` with.

  A missing or unknown request is answered with the newest revision, as the
  specification requires; the client then either accepts it or disconnects.
  """
  @spec negotiate(term()) :: String.t()
  def negotiate(requested) do
    if protocol_version?(requested), do: requested, else: latest_protocol_version()
  end

  @doc "The `serverInfo` object of an `initialize` result."
  @spec server_info() :: map()
  def server_info do
    %{"name" => "confluence-mirror", "title" => Sites.name(), "version" => version()}
  end

  @doc """
  What a client is told before it picks a tool.

  Short on purpose: a model pays for every token, and the tool descriptions
  already say what each tool does. This says the two things a model cannot
  infer — that the mirror is read-only, and that every answer is already
  narrowed to what the authenticated reader may open.
  """
  @spec instructions() :: String.t()
  def instructions do
    """
    This is a read-only mirror of #{Sites.name()}. Nothing here can be created, \
    edited or deleted.

    Search with confluence_search (a text query or Confluence CQL) or, when you \
    have field filters, confluence_advanced_search. Navigate with \
    confluence_list_spaces, confluence_get_space and \
    confluence_get_space_page_tree; read a page with confluence_get_page, which \
    returns Markdown by default.

    Two tools sound alike and are not: confluence_get_recent_changes lists content \
    whose Confluence timestamp is newest, while confluence_index_status (mirror \
    administrators only) says what the mirror ingested and when — the answer to \
    "what are the last spaces indexed?".

    Every result is filtered to the content the authenticated reader may open, \
    exactly like the web UI: a page you are not allowed to read is reported as \
    not mirrored, and it does not appear in search, trees, children or backlinks.
    """
  end

  defp version do
    case Application.spec(:confluence_phx_mirror, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
