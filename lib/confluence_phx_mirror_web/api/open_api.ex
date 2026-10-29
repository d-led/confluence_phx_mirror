defmodule ConfluencePhxMirrorWeb.Api.OpenApi do
  @moduledoc """
  The OpenAPI 3.1 description of the mirror's read-only APIs.

  The document is served at `/api/openapi.json` and rendered for humans at
  `/api/docs`. It describes both surfaces: the first-party JSON API under
  `/api/v1` and the Confluence-compatible subset under `/wiki/rest/api`, plus
  `/health`.

  **The paths come from the router.** Every `GET` the router serves below those
  prefixes is in the document because it is in the router — a new endpoint shows
  up without anyone remembering to add it. What the router cannot say is what an
  endpoint *means*, so each route is described in `operations/0`, keyed by verb
  and path template. `undocumented/0` lists the routes that are still missing
  their description, and a test keeps that list empty: a route cannot ship
  unexplained, and a description cannot outlive its route.

  Written by hand rather than generated from controller specs on purpose. The
  shapes here are the presenter maps — a few dozen fields, described once — and
  `open_api_spex` would add a dependency, an operation module per action and a
  second way to say the same thing for little that this needs. What it would add
  is response validation, which the controller tests already cover per endpoint.

  The surface can be switched off (`CM_API_DOCS`) because a deployment may not
  want to advertise it; `enabled?/0` is the single place that answers.
  """

  alias ConfluencePhxMirror.BuildInfo
  alias ConfluencePhxMirror.Sites
  alias ConfluencePhxMirrorWeb.Router

  @json "application/json"

  @api_prefixes ["/api/v1", "/wiki/rest/api"]

  @tags [
    %{"name" => "Spaces", "description" => "Spaces and the pages in them."},
    %{
      "name" => "Pages",
      "description" => "Pages, their structure, labels, attachments and comments."
    },
    %{"name" => "Labels", "description" => "Labels in use across the mirror."},
    %{
      "name" => "Search",
      "description" =>
        "Structured search (`q` plus filters). Raw CQL stays on the Confluence-compatible surface."
    },
    %{"name" => "Stats", "description" => "Content counters and the last sync."},
    %{
      "name" => "Sync runs",
      "description" =>
        "The sync history: a window at a time, and the whole of it as a stream. Administrator-only."
    },
    %{
      "name" => "Identities",
      "description" =>
        "The Confluence accounts the content names, and pairing one with an account here. Administrator-only."
    },
    %{"name" => "Health", "description" => "Liveness and readiness; needs no token."},
    %{
      "name" => "Confluence-compatible",
      "description" =>
        "The subset an existing Confluence client expects: `results`, `start`, `limit`, `size`, `_links`, and raw CQL on `search`."
    }
  ]

  # The routes that matter to clients but are not `GET`s under an API prefix:
  # `/health`, and the two writes an administrator may make on an identity.
  @extra_routes [
    {"get", "/health"},
    {"post", "/api/v1/identities/{account_id}/link"},
    {"delete", "/api/v1/identities/{account_id}/link"},
    {"post", "/api/v1/users"},
    {"post", "/api/v1/spaces"},
    {"delete", "/api/v1/spaces/{key}"}
  ]

  # ---------------------------------------------------------------------------
  # Public interface
  # ---------------------------------------------------------------------------

  @doc "Whether the description and its page are served at all."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:confluence_phx_mirror, :api_docs, true)

  @doc "The document as a plain map, ready to be encoded as JSON."
  @spec document() :: map()
  def document do
    # `Sites.name/0` already answers a neutral name for a mirror with no site.
    site = Sites.name()

    %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => "Confluence Mirror API",
        "version" => BuildInfo.info().version,
        "description" =>
          "Read-only access to a mirror of #{site}. " <>
            "Two surfaces over the same content: `/api/v1` for first-party clients and " <>
            "`/wiki/rest/api` for tools that already speak Confluence. Nothing here writes.",
        "license" => %{"name" => "MPL-2.0", "identifier" => "MPL-2.0"}
      },
      "servers" => [%{"url" => "/", "description" => "This mirror"}],
      "tags" => @tags,
      "security" => [%{"bearer" => []}, %{"basic" => []}],
      "paths" => paths(),
      "components" => %{
        "securitySchemes" => %{
          "bearer" => %{
            "type" => "http",
            "scheme" => "bearer",
            "description" =>
              "An API token from the admin dashboard: `Authorization: Bearer <token>`."
          },
          "basic" => %{
            "type" => "http",
            "scheme" => "basic",
            "description" =>
              "Confluence-style credentials, `base64(email:token)` — the form Confluence clients already send."
          }
        },
        "schemas" => schemas()
      }
    }
  end

  @doc """
  Every `GET` the router serves under an API prefix, as `{verb, "{param}"}`.

  Sorted for stable rendering and stable tests.
  """
  @spec routes() :: [{String.t(), String.t()}]
  def routes do
    router_routes =
      Router.__routes__()
      |> Enum.filter(&(&1.verb == :get and api_path?(&1.path)))
      |> Enum.map(&{Atom.to_string(&1.verb), template(&1.path)})

    (router_routes ++ @extra_routes)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Routes the router serves that no description covers yet. A test keeps this empty."
  @spec undocumented() :: [{String.t(), String.t()}]
  def undocumented, do: Enum.reject(routes(), &Map.has_key?(operations(), &1))

  @doc "The operations grouped by tag, in reading order, for the HTML page."
  @spec sections() :: [%{tag: String.t(), description: String.t(), operations: [map()]}]
  def sections do
    documented =
      for {path, operations} <- document()["paths"],
          {verb, operation} <- operations,
          do: Map.put(operation, "path", path) |> Map.put("verb", verb)

    for tag <- @tags do
      operations =
        documented
        |> Enum.filter(&(&1["tags"] == [tag["name"]]))
        |> Enum.sort_by(& &1["path"])

      %{tag: tag["name"], description: tag["description"], operations: operations}
    end
    |> Enum.reject(&(&1.operations == []))
  end

  # ---------------------------------------------------------------------------
  # Paths and operations
  # ---------------------------------------------------------------------------

  defp paths do
    routes()
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Map.new(fn {path, verbs} ->
      operations = Map.new(verbs, fn verb -> {verb, operation(verb, path)} end)
      {path, operations}
    end)
  end

  defp operation(verb, path) do
    case Map.fetch(operations(), {verb, path}) do
      {:ok, described} ->
        %{
          "operationId" => operation_id(verb, path),
          "tags" => [described.tag],
          "summary" => described.summary,
          "parameters" => Enum.map(described[:params] || [], &parameter/1),
          "responses" =>
            Map.new(described.responses, fn {status, body} -> {to_string(status), body} end)
        }
        |> put_description(Map.get(described, :description))
        |> put_body(Map.get(described, :body))
        |> put_security(Map.get(described, :auth, true))

      # Generated from the router so the document never silently loses an
      # endpoint; `undocumented/0` (and a test) flags it as unfinished.
      :error ->
        %{
          "operationId" => operation_id(verb, path),
          "tags" => [tag_for(path)],
          "summary" => "#{String.upcase(verb)} #{path}",
          "description" => "Not described yet — this entry was generated from the router.",
          "responses" => %{"200" => %{"description" => "OK"}}
        }
        |> put_security(true)
    end
  end

  # `description: nil` is not the same as no description: the field may not be
  # null, so it is left out entirely. (Redocly caught this one.)
  defp put_description(operation, nil), do: operation
  defp put_description(operation, text), do: Map.put(operation, "description", text)

  # A write names its body's schema; the document says so once, so a client
  # generator has something to build a request object from.
  defp put_body(operation, nil), do: operation

  defp put_body(operation, schema) do
    Map.put(operation, "requestBody", %{
      "required" => true,
      "content" => %{@json => %{"schema" => ref(schema)}}
    })
  end

  defp put_security(operation, false), do: operation

  # Every token-protected call answers 401 for a bad or missing token, so the
  # document says so once instead of in each entry.
  defp put_security(operation, true) do
    operation
    |> Map.put("security", [%{"bearer" => []}, %{"basic" => []}])
    |> Map.update(
      "responses",
      %{},
      &Map.put_new(&1, "401", error("No token, or a token that is invalid or expired."))
    )
  end

  # `GET /api/v1/pages/{id}` is `getApiV1PagesId`, stable enough to generate a
  # client from.
  defp operation_id(verb, path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map_join("", &String.capitalize/1)
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> then(&(verb <> &1))
  end

  defp tag_for("/api/v1" <> _), do: "Pages"
  defp tag_for("/wiki/rest/api" <> _), do: "Confluence-compatible"
  defp tag_for(_path), do: "Health"

  # ---------------------------------------------------------------------------
  # The description table
  # ---------------------------------------------------------------------------

  # Every route the router serves below `/api/v1` and `/wiki/rest/api` needs an
  # entry here. `path` params are typed; `query` params are the ones the
  # controllers actually read.
  defp operations do
    %{
      {"get", "/api/v1/spaces"} => %{
        tag: "Spaces",
        summary: "List the spaces this caller can read",
        description:
          "Every mirrored space with its page count, in Confluence's list envelope. " <>
            "Spaces the caller may not read are left out rather than refused.",
        responses: %{200 => ok("SpaceList")}
      },
      {"get", "/api/v1/spaces/{key}"} => %{
        tag: "Spaces",
        summary: "One space",
        description: "The space, its homepage and when it was last synced.",
        params: [path_param("key", %{"type" => "string"}, "The space key, e.g. `ENG`.")],
        responses: %{
          200 => ok("Space"),
          404 => error("The space is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/spaces/{key}/pages"} => %{
        tag: "Pages",
        summary: "The pages of one space",
        description:
          "Newest first, without bodies. `start`/`limit` window the list and `_links.next` " <>
            "carries the next window while there is one.",
        params: [
          path_param("key", %{"type" => "string"}, "The space key."),
          query_param("start", %{"type" => "integer", "minimum" => 0}, "Offset, default 0."),
          query_param(
            "limit",
            %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "Window size, default 25, at most 100."
          )
        ],
        responses: %{
          200 => ok("PageList"),
          404 => error("The space is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/pages/{id}"} => %{
        tag: "Pages",
        summary: "One page, with both bodies",
        description:
          "The full representation: `body.storage` as Confluence sent it, `body.export_view` " <>
            "as the mirror renders it, plus version, labels, ancestors and provenance.",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("Page"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/pages/{id}/children"} => %{
        tag: "Pages",
        summary: "The direct children of a page",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("PageList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/pages/{id}/ancestors"} => %{
        tag: "Pages",
        summary: "The trail from the root to a page",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("PageList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/pages/{id}/descendants"} => %{
        tag: "Pages",
        summary: "Every page below a page, level by level",
        description:
          "Transitive descendants, not just children: the whole branch below the page. A " <>
            "branch can be hundreds of pages, so it is windowed like any listing — `limit` " <>
            "is 25 by default and `_links.next` continues. Order is level order: every page " <>
            "before the pages below it, siblings by title. `depth` says how far below the " <>
            "named page a result sits (a direct child is 1) and `parent` names the row above " <>
            "it. Pages the caller may not read are left out, so a row's `parent` can name a " <>
            "page this listing does not contain.",
        params: [
          path_param("id", %{"type" => "integer"}, "The Confluence content id."),
          query_param("start", %{"type" => "integer", "minimum" => 0}, "Offset, default 0."),
          query_param(
            "limit",
            %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "Window size, default 25, at most 100."
          )
        ],
        responses: %{
          200 => ok("DescendantList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/pages/{id}/labels"} => %{
        tag: "Pages",
        summary: "The labels of a page",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("LabelList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/pages/{id}/attachments"} => %{
        tag: "Pages",
        summary: "The attachments of a page",
        description: "Metadata only; `_links.download` serves the bytes.",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("AttachmentList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/pages/{id}/comments"} => %{
        tag: "Pages",
        summary: "The comments of a page, replies included",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("CommentList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/pages/{id}/backlinks"} => %{
        tag: "Pages",
        summary: "The pages that link to this one",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("PageList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/page-by-path"} => %{
        tag: "Pages",
        summary: "One page by space and id",
        description:
          "The same representation as `/api/v1/pages/{id}`, addressed the way a link does.",
        params: [
          query_param(
            "space",
            %{"type" => "string"},
            "The space key (`spaceKey` is accepted too).",
            required: true
          ),
          query_param("id", %{"type" => "integer"}, "The Confluence content id.", required: true)
        ],
        responses: %{
          200 => ok("Page"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/api/v1/labels"} => %{
        tag: "Labels",
        summary: "Labels with page counts",
        description:
          "Counted over what the caller may read, so two callers can see different numbers.",
        responses: %{200 => ok("LabelList")}
      },
      {"get", "/api/v1/search"} => %{
        tag: "Search",
        summary: "Structured search",
        description:
          "At least one of the filters is required. Text queries support uppercase `AND`/`OR`/`NOT`, " <>
            "parentheses, quoted phrases and `prefix*`; `updated` takes `7d`/`30d`/`90d`/`365d` or an ISO date. " <>
            "Every hit carries a `snippet` and a `rank` beside the page summary.",
        params: [
          query_param("q", %{"type" => "string"}, "Free text over title and body."),
          query_param("space", %{"type" => "string"}, "Space key."),
          query_param("label", %{"type" => "string"}, "Label name."),
          query_param(
            "type",
            %{"type" => "string", "enum" => ~w(page blogpost)},
            "Content type."
          ),
          query_param("creator", %{"type" => "string"}, "Author account id."),
          query_param("ancestor", %{"type" => "integer"}, "Only pages below this content id."),
          query_param("updated", %{"type" => "string"}, "Window, e.g. `7d`, or an ISO date."),
          query_param("start", %{"type" => "integer", "minimum" => 0}, "Offset, default 0."),
          query_param(
            "limit",
            %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "Window size, default 25, at most 100."
          )
        ],
        responses: %{
          200 => ok("SearchList"),
          400 => error("No filter was given, or the query could not be parsed.")
        }
      },
      {"get", "/api/v1/stats"} => %{
        tag: "Stats",
        summary: "Content counters and the last sync",
        responses: %{200 => ok("Stats")}
      },
      {"get", "/api/v1/sync-runs"} => %{
        tag: "Sync runs",
        summary: "The sync history, newest first",
        description:
          "Administrator-only. One row per run — every schedule tick, every one-page sync and every webhook " <>
            "delivery — so the table grows for as long as the mirror exists. This endpoint is a window with the " <>
            "total beside it; `_links.next` carries the next window while there is one.",
        params: [
          query_param("start", %{"type" => "integer", "minimum" => 0}, "Offset, default 0."),
          query_param(
            "limit",
            %{"type" => "integer", "minimum" => 1, "maximum" => 500},
            "Window size, default 50, at most 500."
          )
        ],
        responses: %{
          200 => ok("SyncRunList"),
          403 => error("The token does not belong to an administrator.")
        }
      },
      {"get", "/api/v1/sync-runs/export"} => %{
        tag: "Sync runs",
        summary: "The whole sync history as a stream",
        description:
          "Administrator-only. `format=jsonl` (the default here is CSV for a browser, JSON lines for a " <>
            "script) writes one run per line as it is read, oldest first, in keyset batches — a hundred " <>
            "thousand runs cost one batch of memory and hold no transaction open while the download crawls.",
        params: [
          query_param(
            "format",
            %{"type" => "string", "enum" => ["jsonl", "ndjson", "csv"]},
            "`jsonl`/`ndjson`, or `csv` for a spreadsheet."
          )
        ],
        responses: %{
          200 => %{
            "description" => "The history, streamed as a file.",
            "content" => %{
              "application/x-ndjson" => %{"schema" => %{"type" => "string"}},
              "text/csv" => %{"schema" => %{"type" => "string"}}
            }
          },
          403 => error("The token does not belong to an administrator.")
        }
      },
      {"get", "/api/v1/identities"} => %{
        tag: "Identities",
        summary: "The Confluence accounts the content names",
        description:
          "Administrator-only. A mirror is not a user directory: Confluence Cloud lists no site users, so these " <>
            "are the identities the content itself names — authors of pages and comments, and the account ids " <>
            "permissions carry. Each comes with the groups the last sync read and the account it already stands " <>
            "for. One person often holds two Atlassian accounts; `POST …/link` is how an administrator says they " <>
            "are one person.",
        params: [
          query_param(
            "q",
            %{"type" => "string"},
            "Name or account id, matched case-insensitively."
          ),
          query_param("offset", %{"type" => "integer", "minimum" => 0}, "Offset, default 0."),
          query_param(
            "limit",
            %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "Window size, default 25, at most 100."
          )
        ],
        responses: %{
          200 => ok("IdentityList"),
          403 => error("The token does not belong to an administrator.")
        }
      },
      {"post", "/api/v1/identities/{account_id}/link"} => %{
        tag: "Identities",
        summary: "Stand an account on an identity",
        description:
          "Administrator-only. What the identity carries — its group memberships, the pages and spaces it is " <>
            "named in — becomes the account's, because every permission rule asks the union of an account's " <>
            "identities. Two things are refused: an identity the mirror has never seen, and one another account " <>
            "already holds.",
        params: [
          path_param("account_id", %{"type" => "string"}, "The Confluence account id.")
        ],
        body: "IdentityLink",
        responses: %{
          200 => ok("IdentityLinkResult"),
          403 => error("The token does not belong to an administrator."),
          404 =>
            error(
              "The mirror has never seen this identity, or no account here has that id or e-mail."
            ),
          409 => error("Already that account's, or already another account's."),
          422 => error("Neither `user_id` nor `email` was given.")
        }
      },
      {"delete", "/api/v1/identities/{account_id}/link"} => %{
        tag: "Identities",
        summary: "Take an identity away from its account",
        description:
          "Administrator-only. What the identity carries stops being the account's. The identity an account " <>
            "signs in with is not a link and is refused here — taking it away would lock the reader out of their " <>
            "own account, not narrow what it may read.",
        params: [
          path_param("account_id", %{"type" => "string"}, "The Confluence account id.")
        ],
        responses: %{
          200 => ok("IdentityLinkResult", "The identity, now standing for nobody."),
          403 => error("The token does not belong to an administrator."),
          404 => error("No account here stands on this identity."),
          409 => error("That identity is the account's own sign-in identity, not a link.")
        }
      },
      {"post", "/api/v1/users"} => %{
        tag: "Identities",
        summary: "Create an account before its person arrives",
        description:
          "Administrator-only. The account exists from now on, with no sign-in and no Confluence credentials: " <>
            "link a Confluence identity to it, put it in a group, watch it — all before the person opens the " <>
            "mirror. Their first sign-in with that address claims it, and no sync ever takes it away.",
        body: "CreateUserRequest",
        responses: %{
          201 => ok("Account", "The account was created."),
          403 => error("The token does not belong to an administrator."),
          422 => error("The address is missing, malformed, or already in use.")
        }
      },
      {"post", "/api/v1/spaces"} => %{
        tag: "Spaces",
        summary: "Import one more space",
        description:
          "Administrator-only. Adds a key to the whitelist a run imports — the deployment's `CM_SPACES` plus " <>
            "the keys added here. It only widens: nothing stops being imported this way. A mirror that imports " <>
            "every space refuses, because naming one key would narrow it to that key and the next run would " <>
            "trash the rest; set `CM_SPACES` to narrow a mirror.",
        body: "SpaceWhitelistRequest",
        responses: %{
          201 => ok("SpaceWhitelist", "The key was added."),
          403 => error("The token does not belong to an administrator."),
          409 => error("This mirror imports every space; set `CM_SPACES` first."),
          422 => error("No `key` was given.")
        }
      },
      {"delete", "/api/v1/spaces/{key}"} => %{
        tag: "Spaces",
        summary: "Stop importing a space",
        description:
          "Administrator-only. Removes a key from the runtime whitelist. The next run stops importing it and " <>
            "trashes what it holds — softly: rows stay, and naming the key again brings them back. A key " <>
            "`CM_SPACES` names stays in force and the answer says so. `pages_awaiting_trash` is what the next " <>
            "run will move, not what it has moved.",
        params: [path_param("key", %{"type" => "string"}, "Space key, case-insensitive.")],
        responses: %{
          200 => ok("SpaceRemoval", "The removal was recorded."),
          403 => error("The token does not belong to an administrator."),
          422 => error("The change was not stored.")
        }
      },
      {"get", "/health"} => %{
        tag: "Health",
        summary: "Liveness and readiness",
        description:
          "Checks the database and reports the counters and the last sync. `503` when the database " <>
            "is unreachable, so it can back a probe. Needs no token.",
        auth: false,
        responses: %{200 => ok("Health"), 503 => ok("Health", "The database is unreachable.")}
      },
      {"get", "/wiki/rest/api/space"} => %{
        tag: "Confluence-compatible",
        summary: "Spaces, Confluence style",
        description: "Same envelope Confluence returns: `results`, `size`, `_links`.",
        responses: %{200 => ok("SpaceList")}
      },
      {"get", "/wiki/rest/api/space/{key}"} => %{
        tag: "Confluence-compatible",
        summary: "One space, Confluence style",
        params: [path_param("key", %{"type" => "string"}, "The space key.")],
        responses: %{
          200 => ok("Space"),
          404 => error("The space is not mirrored, or not readable.")
        }
      },
      {"get", "/wiki/rest/api/content"} => %{
        tag: "Confluence-compatible",
        summary: "Content of a space, Confluence style",
        params: [
          query_param("spaceKey", %{"type" => "string"}, "The space key."),
          query_param("start", %{"type" => "integer", "minimum" => 0}, "Offset, default 0."),
          query_param(
            "limit",
            %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "Window size, default 25, at most 100."
          )
        ],
        responses: %{
          200 => ok("PageList"),
          404 => error("The space is not mirrored, or not readable.")
        }
      },
      {"get", "/wiki/rest/api/content/{id}"} => %{
        tag: "Confluence-compatible",
        summary: "One content item, Confluence style",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("Page"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/wiki/rest/api/content/{id}/child/page"} => %{
        tag: "Confluence-compatible",
        summary: "Children, Confluence style",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("PageList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/wiki/rest/api/content/{id}/descendant/page"} => %{
        tag: "Confluence-compatible",
        summary: "Descendants, Confluence style",
        description:
          "Confluence's own route for the branch below a page: every page below it, not " <>
            "just its children, in level order and windowed — `limit` is 25 by default.",
        params: [
          path_param("id", %{"type" => "integer"}, "The Confluence content id."),
          query_param("start", %{"type" => "integer", "minimum" => 0}, "Offset, default 0."),
          query_param(
            "limit",
            %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "Window size, default 25, at most 100."
          )
        ],
        responses: %{
          200 => ok("DescendantList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/wiki/rest/api/content/{id}/child/attachment"} => %{
        tag: "Confluence-compatible",
        summary: "Attachments, Confluence style",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("AttachmentList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/wiki/rest/api/content/{id}/child/comment"} => %{
        tag: "Confluence-compatible",
        summary: "Comments, Confluence style",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("CommentList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/wiki/rest/api/content/{id}/label"} => %{
        tag: "Confluence-compatible",
        summary: "Labels, Confluence style",
        params: [path_param("id", %{"type" => "integer"}, "The Confluence content id.")],
        responses: %{
          200 => ok("LabelList"),
          404 => error("The page is not mirrored, or not readable.")
        }
      },
      {"get", "/wiki/rest/api/content/search"} => %{
        tag: "Confluence-compatible",
        summary: "Raw CQL search",
        description: "The one place raw CQL is public, because that is Confluence's contract.",
        params: cql_params(),
        responses: %{
          200 => ok("CqlList"),
          400 => error("`cql` is missing or could not be parsed.")
        }
      },
      {"get", "/wiki/rest/api/search"} => %{
        tag: "Confluence-compatible",
        summary: "Raw CQL search (alias)",
        description:
          "`/wiki/rest/api/content/search` is the documented path; this alias answers the same.",
        params: cql_params(),
        responses: %{
          200 => ok("CqlList"),
          400 => error("`cql` is missing or could not be parsed.")
        }
      }
    }
  end

  defp cql_params do
    [
      query_param(
        "cql",
        %{"type" => "string"},
        "Confluence query language, e.g. `space = ENG AND label = architecture`.",
        required: true
      ),
      query_param("start", %{"type" => "integer", "minimum" => 0}, "Offset, default 0."),
      query_param(
        "limit",
        %{"type" => "integer", "minimum" => 1, "maximum" => 100},
        "Window size, default 25, at most 100."
      )
    ]
  end

  # ---------------------------------------------------------------------------
  # Parameters and responses
  # ---------------------------------------------------------------------------

  defp path_param(name, schema, description),
    do: {name, "path", Map.put(schema, "description", description), true}

  defp query_param(name, schema, description, opts \\ []),
    do:
      {name, "query", Map.put(schema, "description", description),
       Keyword.get(opts, :required, false)}

  defp parameter({name, location, schema, required}) do
    %{"name" => name, "in" => location, "required" => required, "schema" => schema}
  end

  defp ok(schema, description \\ "The content, as JSON."),
    do: %{
      "description" => description,
      "content" => %{@json => %{"schema" => ref(schema)}}
    }

  defp error(description) do
    %{
      "description" => description,
      "content" => %{@json => %{"schema" => ref("Error")}}
    }
  end

  defp ref(schema), do: %{"$ref" => "#/components/schemas/#{schema}"}

  # ---------------------------------------------------------------------------
  # Schemas
  # ---------------------------------------------------------------------------

  defp schemas do
    %{
      "Error" =>
        object(
          %{
            "error" => string("A stable code, e.g. `not_found`."),
            "message" => string("What went wrong, in words a person can act on.")
          },
          ~w(error message)
        ),
      "Links" =>
        object(%{
          "base" => string("The mirror's root URL."),
          "self" => string("This resource."),
          "next" => string("The next window, when there is one."),
          "webui" => string("The page in the reader UI."),
          "original" => string("The page on the original Confluence site."),
          "download" => string("The attachment's bytes.")
        }),
      "SpaceRef" =>
        object(
          %{"id" => integer(), "key" => string("The space key."), "name" => string()},
          ~w(id key name)
        ),
      "Space" =>
        object(
          %{
            "id" => integer(),
            "key" => string("The space key."),
            "name" => string(),
            "type" => string("`global` or `personal`."),
            "status" => string("Always `current`."),
            "description" => map_of("plain", map_of("value", string())),
            "homepage" => %{"type" => ["object", "null"]},
            "pageCount" => integer("Only in the list."),
            "_links" => ref("Links"),
            "mirror" => mirror()
          },
          ~w(key name)
        ),
      "SpaceList" => list_of("Space"),
      "SpaceWhitelistRequest" =>
        object(%{"key" => string("The space key to start importing.")}, ~w(key)),
      "CreateUserRequest" =>
        object(
          %{
            "email" => string("The address the person will sign in with."),
            "role" => string("`member` (default) or `admin`.")
          },
          ~w(email)
        ),
      "SpaceWhitelist" =>
        object(%{
          "key" => string("The key this call was about."),
          "every_space" => %{"type" => "boolean"},
          "keys" => %{"type" => "array", "items" => %{"type" => "string"}}
        }),
      "SpaceRemoval" =>
        object(%{
          "key" => string("The key this call was about."),
          "removed" => %{
            "type" => "boolean",
            "description" => "False when `CM_SPACES` still names the key."
          },
          "pages_awaiting_trash" =>
            integer("What the next run will move to the trash, not what it has moved."),
          "every_space" => %{"type" => "boolean"},
          "keys" => %{"type" => "array", "items" => %{"type" => "string"}}
        }),
      "Author" =>
        object(%{
          "displayName" => string(),
          "accountId" => string("The Confluence account id, when the site exposes it.")
        }),
      "Version" =>
        object(%{
          "number" => integer(),
          "message" => string(),
          "when" => string("ISO 8601 date-time."),
          "by" => ref("Author")
        }),
      "Label" => object(%{"name" => string(), "prefix" => string("Always `global`.")}, ~w(name)),
      "PageSummary" =>
        object(
          %{
            "id" => string("The Confluence content id, as a string."),
            "type" => string("`page` or `blogpost`."),
            "status" => string("`current` or `archived`."),
            "title" => string(),
            "space" => ref("SpaceRef"),
            "version" => ref("Version"),
            "metadata" => map_of("labels", map_of("results", array_of(ref("Label")))),
            "_links" => ref("Links"),
            "mirror" => map_of("syncedAt", string("ISO 8601 date-time."))
          },
          ~w(id title space)
        ),
      "PageList" => list_of("PageSummary"),
      "PageDescendant" => %{
        "description" => "A `PageSummary` with where it sits below the page the request named.",
        "allOf" => [
          ref("PageSummary"),
          object(
            %{
              "depth" => integer("Levels below the named page; a direct child is 1."),
              "parent" => %{
                "type" => ["string", "null"],
                "description" => "The content id of the page above this one."
              }
            },
            ~w(depth)
          )
        ]
      },
      "DescendantList" => list_of("PageDescendant"),
      "Page" =>
        object(
          %{
            "id" => string("The Confluence content id, as a string."),
            "type" => string(),
            "status" => string(),
            "title" => string(),
            "space" => ref("SpaceRef"),
            "ancestors" => array_of(object(%{"id" => string("The ancestor's content id.")})),
            "version" => ref("Version"),
            "history" => map_of("createdDate", string("ISO 8601 date-time.")),
            "body" =>
              object(%{
                "storage" => representation("storage", "What Confluence stores."),
                "export_view" => representation("view", "Confluence's own macro rendering.")
              }),
            "metadata" => map_of("labels", map_of("results", array_of(ref("Label")))),
            "_links" => ref("Links"),
            "mirror" => mirror()
          },
          ~w(id title space body)
        ),
      "Attachment" =>
        object(
          %{
            "id" => string(),
            "type" => string("Always `attachment`."),
            "title" => string("The filename."),
            "version" => map_of("number", integer()),
            "extensions" => %{
              "type" => "object",
              "properties" => %{"mediaType" => string(), "fileSize" => integer()}
            },
            "_links" => ref("Links")
          },
          ~w(id title)
        ),
      "AttachmentList" => list_of("Attachment"),
      "Comment" =>
        object(
          %{
            "id" => string(),
            "type" => string("Always `comment`."),
            "ancestors" => array_of(object(%{"id" => string()})),
            "body" =>
              map_of(
                "export_view",
                representation("view", "The comment as Confluence renders it.")
              ),
            "_links" => ref("Links")
          },
          ~w(id body)
        ),
      "CommentList" => list_of("Comment"),
      "LabelList" => list_of("Label"),
      "SearchResult" =>
        object(
          %{
            "id" => string(),
            "title" => string(),
            "space" => ref("SpaceRef"),
            "snippet" => string("The matched text with its surroundings."),
            "rank" => %{"type" => "number", "description" => "Relevance, higher first."}
          },
          ~w(id title)
        ),
      "SearchList" =>
        envelope("SearchResult", %{
          "filters" => %{"type" => "object", "description" => "The filters the search ran with."}
        }),
      "CqlList" =>
        envelope("SearchResult", %{
          "cql" => string("The CQL text that was run.")
        }),
      "SyncRunList" => list_of("SyncRun"),
      "SyncRun" =>
        object(
          %{
            "id" => integer("The run's number, the one the audit log and the dashboard print."),
            "source" => string("The reader it synced through, e.g. `confluence-http`."),
            "mode" => string("`snapshot`, `incremental` or `webhook`."),
            "scope" => string("What it covered: the site, a space, or one page."),
            "status" => string("`running`, `succeeded`, `partial`, `failed` or `cancelled`."),
            "startedAt" => string("ISO 8601 date-time."),
            "finishedAt" => %{"type" => ["string", "null"]},
            "durationMs" => %{
              "type" => ["integer", "null"],
              "description" => "Null while the run has not finished."
            },
            "cancelRequestedAt" => %{"type" => ["string", "null"]},
            "stats" => %{"type" => "object"},
            "error" => %{"type" => ["string", "null"]}
          },
          ~w(id source mode status startedAt stats)
        ),
      "Stats" =>
        object(
          %{
            "stats" => %{
              "type" => "object",
              "properties" => %{
                "spaces" => integer(),
                "pages" => integer(),
                "attachments" => integer()
              }
            },
            "lastSync" => %{"type" => ["object", "null"]},
            "source" => map_of("kind", string("`demo` or `live`."))
          },
          ~w(stats)
        ),
      "Health" =>
        object(
          %{
            "status" => string("`ok` or `degraded`."),
            "database" => string("`ok` or `unavailable`."),
            "pages" => integer(),
            "spaces" => integer(),
            "attachments" => integer(),
            "last_sync_at" => string("ISO 8601 date-time, or null before the first sync."),
            "source" => string()
          },
          ~w(status database)
        ),
      "Account" =>
        object(
          %{
            "id" => integer("The account's id in this mirror."),
            "email" => string("The address it signs in with."),
            "displayName" => string(),
            "role" => string("`admin` or `user`.")
          },
          ~w(id email)
        ),
      "Identity" =>
        object(
          %{
            "accountId" => string("The Confluence account id the permissions carry."),
            "displayName" => string("The name the content shows, when it shows one."),
            "groups" => array_of(string("A group the last sync read for this identity.")),
            "linkedTo" => %{
              "description" =>
                "The account that stands for this identity, or null when none does.",
              "oneOf" => [ref("Account"), %{"type" => "null"}]
            }
          },
          ~w(accountId),
          "One Confluence identity — a person's account on the site, as the content names it."
        ),
      "IdentityList" =>
        object(
          %{
            "items" => array_of(ref("Identity")),
            "total" => integer("How many identities match, across every window."),
            "limit" => integer("Window size that was asked for."),
            "offset" => integer("Offset of the first item.")
          },
          ~w(items total
             limit
             offset),
          "A page of identities. A site can name a hundred thousand of them, so this list is searched and paged rather than drawn whole."
        ),
      "IdentityLink" =>
        object(
          %{
            "userId" => integer("The account's id here."),
            "email" => string("Or the address it uses, when the id is not at hand.")
          },
          [],
          "Name the account one way or the other; `userId` wins when both are given."
        ),
      "IdentityLinkResult" =>
        object(
          %{
            "identity" =>
              object(
                %{
                  "accountId" => string("The Confluence account id."),
                  "groups" => array_of(string("The groups the last sync read for it.")),
                  "linkedTo" => %{
                    "description" => "The account it stands for, or null after an unlink.",
                    "oneOf" => [ref("Account"), %{"type" => "null"}]
                  }
                },
                ~w(accountId)
              ),
            "account" => ref("Account")
          },
          ~w(identity account),
          "The identity as it stands after the change, beside the account it belongs to."
        )
    }
  end

  # Confluence's list envelope, shared by every list endpoint.
  defp envelope(item, extra_properties \\ %{}) do
    object(
      Map.merge(
        %{
          "results" => array_of(ref(item)),
          "start" => integer("Offset of the first result."),
          "limit" => integer("Window size that was asked for."),
          "size" => integer("How many results this response carries."),
          "_links" => ref("Links")
        },
        extra_properties
      ),
      ~w(results size),
      "Confluence's list envelope."
    )
  end

  defp list_of(item), do: envelope(item)

  defp representation(representation, description) do
    object(
      %{
        "value" => string(description),
        "representation" => string("Always `#{representation}`.")
      },
      ~w(value)
    )
  end

  defp mirror do
    object(%{
      "syncedAt" => string("When the mirror last read this content."),
      "version" => integer(),
      "source" => string("The original URL.")
    })
  end

  defp object(properties, required \\ [], description \\ nil) do
    schema =
      %{"type" => "object", "properties" => properties}
      |> then(fn schema ->
        if required == [], do: schema, else: Map.put(schema, "required", required)
      end)

    if description, do: Map.put(schema, "description", description), else: schema
  end

  defp map_of(key, value), do: %{"type" => "object", "properties" => %{key => value}}
  defp array_of(items), do: %{"type" => "array", "items" => items}

  defp integer(description \\ nil),
    do:
      if(description,
        do: %{"type" => "integer", "description" => description},
        else: %{"type" => "integer"}
      )

  defp string(description \\ nil),
    do:
      if(description,
        do: %{"type" => "string", "description" => description},
        else: %{"type" => "string"}
      )

  # ---------------------------------------------------------------------------
  # Router plumbing
  # ---------------------------------------------------------------------------

  defp api_path?(path), do: Enum.any?(@api_prefixes, &String.starts_with?(path, &1))

  # `/api/v1/pages/:id` is OpenAPI's `/api/v1/pages/{id}`.
  defp template(path), do: Regex.replace(~r/:(\w+)/, path, "{\\1}")
end
