defmodule ConfluencePhxMirror.Mcp.Tools do
  @moduledoc """
  The tools the MCP server offers, and the one place a name becomes a function.

  Names and arguments follow `mcp-atlassian`'s Confluence toolset where they
  overlap (`confluence_search`, `confluence_get_page`,
  `confluence_get_page_children`, `confluence_get_space_page_tree`,
  `confluence_get_comments`, `confluence_get_labels`,
  `confluence_get_attachments`), so a client configured for that server can be
  pointed at this mirror and keep its prompts. The mirror adds read-only
  navigation tools a static wiki benefits from — an advanced search with the
  UI's filters, ancestors, backlinks, a space listing, recent changes — and
  nothing that writes: a mirror's content changes only through a sync.

  Every tool carries its origin in `_meta` (`atlassian` or `mirror`) and, for
  the mirror's own, says so at the start of its description, so a model and a
  human can both tell which tools are portable.

  Every tool takes the reader's `Scope` and answers with what that reader may
  open. The tools do not implement permissions themselves; they hand
  `ConfluencePhxMirror.Authorization` to the query (`restrict_pages/2`,
  `readable_results/2`) or ask `can_read_page?/2`, exactly like the controllers.
  A page the reader may not open is reported as not mirrored, so a tool call
  cannot be used to confirm that a restricted page exists.

  A tool answers `{:ok, %{text: text, structured: map | nil}}` or
  `{:error, message}`; the protocol layer turns the first into MCP content and
  the second into a tool execution error the model can read and act on.
  """

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Mcp.Tools.{Discussion, Index, Pages, Search, Spaces}

  @read_only %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @tools [
    %{
      "name" => "confluence_search",
      "title" => "Search the mirror",
      "description" =>
        "Search titles, bodies, labels, authors, space names and attachment names. " <>
          "`query` is a Confluence CQL expression when it looks like one " <>
          "(`space = ENG AND type = page`, `title ~ \"roadmap\"`, `label = architecture`), " <>
          "otherwise a full-text query (words are ANDed and prefix-matched; " <>
          "uppercase AND/OR/NOT, quotes and a leading `-` work). " <>
          "Returns the best matches with a snippet and a link.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "A text query or a Confluence CQL expression."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 50,
            "default" => 10,
            "description" => "How many results to return."
          },
          "spaces_filter" => %{
            "type" => "string",
            "description" => "Comma-separated space keys to keep, e.g. `ENG,PROD`."
          }
        },
        "required" => ["query"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_advanced_search",
      "title" => "Advanced search",
      "description" =>
        "The UI's advanced search: any mix of text boxes and field filters. " <>
          "`q` is all of these words, `phrase` is an exact phrase, `any` is any of these " <>
          "words and `none` excludes words. Fields: `space`, `spaces`, `label`, `type` " <>
          "(`page` or `blogpost`), `creator` (display name), `ancestor` (a page id), " <>
          "`updated` (`7d`, `30d`, `90d`, `365d` or an ISO date), `from`/`to` (a range). " <>
          "At least one filter is required.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "q" => %{"type" => "string", "description" => "All of these words."},
          "phrase" => %{"type" => "string", "description" => "An exact phrase."},
          "any" => %{"type" => "string", "description" => "Any of these words."},
          "none" => %{"type" => "string", "description" => "None of these words."},
          "space" => %{"type" => "string", "description" => "One space key."},
          "spaces" => %{
            "type" => "string",
            "description" => "Several space keys, comma-separated (any of them)."
          },
          "label" => %{
            "type" => "string",
            "description" => "A label; several, comma-separated, must all be present."
          },
          "type" => %{"type" => "string", "enum" => ["page", "blogpost"]},
          "creator" => %{"type" => "string", "description" => "Author display name."},
          "ancestor" => %{
            "type" => "string",
            "description" => "A page id; matches its descendants."
          },
          "updated" => %{
            "type" => "string",
            "description" => "`7d`, `30d`, `90d`, `365d`, `any` or an ISO date."
          },
          "from" => %{"type" => "string", "description" => "Earliest update, ISO date."},
          "to" => %{"type" => "string", "description" => "Latest update, ISO date."},
          "sort" => %{
            "type" => "string",
            "enum" => ["relevance", "newest", "oldest"],
            "default" => "relevance"
          },
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 10},
          "start" => %{"type" => "integer", "minimum" => 0, "default" => 0}
        }
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_page",
      "title" => "Get a page",
      "description" =>
        "One page or blog post, as Markdown by default, with a header naming its id, " <>
          "space, URL, version, last update, labels and attachments. Identify it by " <>
          "`page_id` (a Confluence id or a page URL) or by `title` with `space_key`. " <>
          "Set `convert_to_markdown` to false for Confluence storage format " <>
          "(macros and task metadata keep their exact markup, at a higher token cost).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "page_id" => %{
            "type" => "string",
            "description" => "A Confluence content id, or a page URL containing it."
          },
          "title" => %{"type" => "string", "description" => "Exact page title."},
          "space_key" => %{
            "type" => "string",
            "description" => "Space key; required with `title`."
          },
          "include_metadata" => %{
            "type" => "boolean",
            "default" => true,
            "description" => "Whether to include the metadata header."
          },
          "convert_to_markdown" => %{
            "type" => "boolean",
            "default" => true,
            "description" => "Markdown when true, Confluence storage format when false."
          }
        }
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_page_children",
      "title" => "Get child pages",
      "description" =>
        "The pages directly below a page, by title. Set `include_content` to get each " <>
          "child's body too — expensive on a page with many children, so it is off by default.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "parent_id" => %{
            "type" => "string",
            "description" => "The parent's Confluence id or URL."
          },
          "start" => %{"type" => "integer", "minimum" => 0, "default" => 0},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 25},
          "include_content" => %{"type" => "boolean", "default" => false},
          "convert_to_markdown" => %{"type" => "boolean", "default" => true}
        },
        "required" => ["parent_id"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_page_ancestors",
      "title" => "Get a page's ancestors",
      "description" => "The trail from a space's home page down to a page, root first.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "page_id" => %{
            "type" => "string",
            "description" => "A Confluence content id or page URL."
          }
        },
        "required" => ["page_id"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_page_descendants",
      "title" => "Get every page below a page",
      "description" =>
        "Mirror-only: the whole branch below a page, transitively, as an indented list " <>
          "with each page's id, link and depth. Use the children tool for one level and " <>
          "the space tree tool for the shape of a whole space. A branch can be hundreds " <>
          "of pages, so results are windowed: `limit` defaults to 25, and the answer says " <>
          "how many there are and which `start` continues.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "page_id" => %{
            "type" => "string",
            "description" => "A Confluence content id or page URL."
          },
          "start" => %{
            "type" => "integer",
            "minimum" => 0,
            "default" => 0,
            "description" => "How many descendants to skip; the answer names the next start."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 100,
            "default" => 25,
            "description" => "How many descendants to return."
          }
        },
        "required" => ["page_id"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_space_page_tree",
      "title" => "Get a space's page tree",
      "description" =>
        "The page hierarchy of one space as an indented list, with each page's id and " <>
          "link. Pages the reader may not open are left out, and a page whose parent is " <>
          "left out is drawn as a root rather than revealing the hidden branch.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "space_key" => %{"type" => "string", "description" => "Space key, e.g. `ENG`."},
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 1000,
            "default" => 200,
            "description" => "Maximum pages in the tree."
          }
        },
        "required" => ["space_key"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_comments",
      "title" => "Get page comments",
      "description" => "The comments and replies on a page, oldest first, with their authors.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "page_id" => %{
            "type" => "string",
            "description" => "A Confluence content id or page URL."
          },
          "convert_to_markdown" => %{"type" => "boolean", "default" => true}
        },
        "required" => ["page_id"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_labels",
      "title" => "Get a page's labels",
      "description" => "The labels a page or blog post carries, and where each label leads.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "page_id" => %{
            "type" => "string",
            "description" => "A Confluence content id or page URL."
          }
        },
        "required" => ["page_id"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_attachments",
      "title" => "Get page attachments",
      "description" =>
        "The files attached to a page: name, media type, size and download URL. " <>
          "The bytes are not returned; the URLs accept the same credentials as this server.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "page_id" => %{
            "type" => "string",
            "description" => "A Confluence content id or page URL."
          }
        },
        "required" => ["page_id"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_backlinks",
      "title" => "Get backlinks",
      "description" =>
        "The pages that link to a page — useful for finding where a topic is discussed.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "page_id" => %{
            "type" => "string",
            "description" => "A Confluence content id or page URL."
          },
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 25}
        },
        "required" => ["page_id"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_list_spaces",
      "title" => "List spaces",
      "description" =>
        "The spaces the reader may see, by name, optionally narrowed by a word that " <>
          "matches the key or the name. The place to start when the caller does not " <>
          "know a space key yet.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "A word that the space key or name contains."
          },
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 25}
        }
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_space",
      "title" => "Get a space",
      "description" =>
        "One space: its name, description, labels, home page and how many pages the " <>
          "reader may open in it.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "space_key" => %{"type" => "string", "description" => "Space key, e.g. `ENG`."}
        },
        "required" => ["space_key"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_list_blog_posts",
      "title" => "List blog posts",
      "description" => "A space's blog posts (news, release notes), newest first.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "space_key" => %{"type" => "string", "description" => "Space key, e.g. `PROD`."},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 20}
        },
        "required" => ["space_key"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_get_recent_changes",
      "title" => "Recently updated content",
      "description" =>
        "Content whose Confluence `updated` timestamp is most recent, across the mirror " <>
          "or within one space. This is content recency, **not** the ingestion order: for " <>
          "what was indexed last, when a space was last synced, or whether the last run " <>
          "failed, call `confluence_index_status` (administrators only).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "space_key" => %{"type" => "string", "description" => "Optional space key."},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 20}
        }
      },
      "annotations" => @read_only
    },
    %{
      "name" => "confluence_index_status",
      "title" => "Indexing status: last spaces indexed",
      "description" =>
        "What the mirror ingested and when: the answer to what are the last spaces " <>
          "indexed, when was this space last synced, and did the last run fail. Mirror " <>
          "administrators only: lists the most recent sync runs, every space with the " <>
          "time the sync last read it (newest first), and the totals. Ingestion history, " <>
          "not content: use `confluence_get_recent_changes` for content that changed " <>
          "upstream.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "space_key" => %{
            "type" => "string",
            "description" => "One space key, for \"when was this space last read?\"."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 50,
            "default" => 10,
            "description" => "How many spaces to list."
          },
          "runs" => %{
            "type" => "integer",
            "minimum" => 0,
            "maximum" => 20,
            "default" => 5,
            "description" => "How many recent sync runs to list; 0 for none."
          }
        }
      },
      "annotations" => @read_only
    }
  ]

  @dispatch %{
    "confluence_search" => {Search, :search},
    "confluence_advanced_search" => {Search, :advanced},
    "confluence_get_page" => {Pages, :get},
    "confluence_get_page_children" => {Pages, :children},
    "confluence_get_page_ancestors" => {Pages, :ancestors},
    "confluence_get_page_descendants" => {Pages, :descendants},
    "confluence_get_space_page_tree" => {Pages, :tree},
    "confluence_get_backlinks" => {Pages, :backlinks},
    "confluence_get_comments" => {Discussion, :comments},
    "confluence_get_labels" => {Discussion, :labels},
    "confluence_get_attachments" => {Discussion, :attachments},
    "confluence_list_spaces" => {Spaces, :list},
    "confluence_get_space" => {Spaces, :get},
    "confluence_list_blog_posts" => {Spaces, :blog_posts},
    "confluence_get_recent_changes" => {Spaces, :recent},
    "confluence_index_status" => {Index, :status}
  }

  # The names `mcp-atlassian` already defines, so prompts and habits written for
  # that server carry over unchanged. Everything else is this mirror's own.
  @atlassian_tools ~w(
    confluence_search
    confluence_get_page
    confluence_get_page_children
    confluence_get_space_page_tree
    confluence_get_comments
    confluence_get_labels
    confluence_get_attachments
  )

  # A tool says where it comes from twice: in `_meta`, for a client that reads
  # structure, and in the description, for the model that only reads prose.
  # Built per call rather than once in an attribute: a `for` in a module body
  # cannot read another attribute, and `tools/list` asks once a session.
  @doc "The `tools/list` payload."
  @spec definitions() :: [map()]
  def definitions do
    Enum.map(@tools, fn tool ->
      origin = if tool["name"] in @atlassian_tools, do: "atlassian", else: "mirror"

      tool
      |> Map.put("description", described(tool["description"], origin))
      |> Map.put("_meta", %{"confluence-mirror/origin" => origin})
    end)
  end

  defp described(description, "atlassian"), do: description

  defp described(description, "mirror"),
    do: "Mirror-only (mcp-atlassian has no such tool). " <> description

  @doc """
  The names `mcp-atlassian` also defines — the compatible subset of the list.

  Named rather than inferred so a rename in either server shows up as a test
  failure and a documentation diff, not as a prompt that quietly stops working.
  """
  @spec atlassian_tools() :: [String.t()]
  def atlassian_tools, do: @atlassian_tools

  @doc "The tool names, for tests and documentation drift checks."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1["name"])

  @doc """
  Runs a tool as `scope`.

  `:unknown_tool` is distinct from `{:error, _}` on purpose: the protocol layer
  answers the first with a JSON-RPC error (the request named something that
  does not exist) and the second with a tool result that says what went wrong.
  """
  @spec call(String.t(), map(), Scope.t()) ::
          {:ok, %{text: String.t(), structured: map() | nil}}
          | {:error, String.t()}
          | :unknown_tool
  def call(name, arguments, %Scope{} = scope) when is_map(arguments) do
    case Map.fetch(@dispatch, name) do
      {:ok, {module, function}} -> apply(module, function, [arguments, scope])
      :error -> :unknown_tool
    end
  end

  def call(_name, _arguments, %Scope{}), do: {:error, "Tool arguments must be a JSON object."}
end
