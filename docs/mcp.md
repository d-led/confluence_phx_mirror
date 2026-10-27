# MCP server

A **read-only** [Model Context Protocol](https://modelcontextprotocol.io) server:
an assistant can search the mirror, walk its space trees and read pages as
Markdown. No tool call changes anything — content changes only through
[Sync](site-admin-guide.md#pulling-content).

## Connect in two steps

| Step | Local demo | Deployed mirror |
| --- | --- | --- |
| 1. point the client at | `http://localhost:4000/api/mcp` | `https://your-mirror-url/api/mcp` |
| 2. credentials | none (development assumes an administrator) | nothing to paste: the client opens a browser and authorizes itself |

In VS Code, put the block below in `.vscode/mcp.json` (the file is gitignored).
The local one is the demo mirror:

```json
{
  "servers": {
    "confluence-mirror": {
      "type": "http",
      "url": "http://localhost:4000/api/mcp"
    }
  }
}
```

Deployed, the same block with your host — the client walks the OAuth flow itself:

```json
{
  "servers": {
    "confluence-mirror": {
      "type": "http",
      "url": "https://your-mirror-url/api/mcp"
    }
  }
}
```

## Endpoint

`POST /api/mcp` — one JSON-RPC 2.0 message per request, answered with one JSON object.
Streamable HTTP, without the optional parts:

* no SSE stream, no server-initiated messages → `GET` answers **405**;
* no `Mcp-Session-Id`, so any replica can answer any request → `DELETE` answers **405**;
* `OPTIONS` answers **204** with `Allow: POST, DELETE`;
* protocol revisions `2025-06-18`, `2025-03-26`, `2024-11-05`. `initialize` echoes the
  one asked for, or the newest for an unknown one. A `MCP-Protocol-Version` header that
  names none of them is a **400**;
* an `Origin` header, when present, must be this host (DNS-rebinding defence);
* a batch is refused — MCP has no batches;
* calls spend the **API** rate-limit budget (`CM_RATE_LIMIT_API_PER_MINUTE`).

## Authentication

There is no token to paste. The mirror is its own OAuth 2.1 authorization server for
MCP, and a client that supports remote servers walks the flow by itself:

1. `POST /api/mcp` without a token → **401** with
   `WWW-Authenticate: Bearer realm="confluence-mirror", resource_metadata="…/.well-known/oauth-protected-resource"`;
2. the client reads `/.well-known/oauth-protected-resource` and
   `/.well-known/oauth-authorization-server`, then **registers itself** at
   `POST /oauth/register` (public client, no secret);
3. the reader's browser opens `GET /oauth/authorize` — `oauth2-proxy` logs them in if
   they are not already, and the mirror shows one consent screen: *allow this client to
   read as you?*;
4. approving redirects back with a code, and `POST /oauth/token` trades it (PKCE S256,
   code valid one minute) for an access token good for **12 hours**.

The access token is a signed, self-describing value — no session, no table, so any
replica can verify it. It names the **reader who approved it**, so the assistant sees
exactly what that person may see; revoking is about the account: disabling a reader
stops their next call, and rotating `SECRET_KEY_BASE` invalidates every issued token.

| Caller | Credential |
| --- | --- |
| demo mirror (development, test: `MIRROR_AUTO_ADMIN=true`) | none — answered as an administrator |
| MCP client that speaks OAuth | the flow above, no manual step |
| scripts and other clients | `Authorization: Bearer <API token>` (*Users & tokens* in `/admin`) |
| Confluence-style clients | `Authorization: Basic base64(email:token)` |
| nothing | `401` with the challenge above |

Both credentials are parsed in `Plugs.ApiAuth.identity/1`, the same code `/api/v1`
uses, so a token is worth the same on every surface. The API token stays available for
a client that cannot do OAuth discovery; it is a fallback, not the recommended path.

### What oauth2-proxy still has to do (Fly, Kubernetes)

oauth2-proxy is an OIDC *client*: it logs the human in and sets `X-Forwarded-Email`.
It does not issue tokens — the mirror does. It only has to stop answering the
machine-to-machine paths with its own 302 to GitHub, and the shipped proxy config
does: `deploy/fly/proxy/fly.toml` and `deploy/k8s/oauth2-proxy.yaml` skip
`/api/…` (the MCP endpoint among it), `/oauth/(token|register)` and
`/.well-known/…`.

`/oauth/authorize` is **not** skipped: that is the browser step, and the proxy is
what identifies the reader there (`CM_PROXY_AUTH=true`). On Fly, `PHX_HOST` gives
the mirror its public URL, which is what the discovery documents advertise.
[routes-auth.md](routes-auth.md) has the whole set, and the difference between a
sign-in redirect, an `401` challenge and the mirror's own refusal.

## Authorization

Every tool runs as the authenticated reader and asks the same questions the HTML pages
and the JSON API ask — `Authorization.can_read_page?/2`, `restrict_pages/2`,
`readable_results/2`, `readable_spaces/2`. A page the reader may not open is reported as
**not mirrored**, in the same words as a page that does not exist: a tool call cannot be
used to confirm that a restricted page exists. Search hits, children, trees, backlinks
and space listings are narrowed inside their query, so restricted titles never reach the
client. A page whose parent is hidden appears as a tree root, not as a deeper node.

## Tools

`origin` says whether the name and arguments are `mcp-atlassian`'s (portable: a client
configured for that server keeps its prompts) or this mirror's own. Every tool also
carries it in `_meta` as `confluence-mirror/origin`, and the mirror's own say
"Mirror-only" at the start of their description.

| Tool | Origin | Answers | Arguments |
| --- | --- | --- | --- |
| `confluence_search` | atlassian | text or CQL search, ranked, with snippets | `query`, `limit`, `spaces_filter` |
| `confluence_get_page` | atlassian | one page: Markdown (default) or storage format | `page_id` or `title`+`space_key`, `include_metadata`, `convert_to_markdown` |
| `confluence_get_page_children` | atlassian | direct children, optionally with bodies | `parent_id`, `start`, `limit`, `include_content`, `convert_to_markdown` |
| `confluence_get_space_page_tree` | atlassian | an indented hierarchy of a space | `space_key`, `limit` |
| `confluence_get_comments` | atlassian | comments and replies, oldest first | `page_id`, `convert_to_markdown` |
| `confluence_get_labels` | atlassian | a page's labels | `page_id` |
| `confluence_get_attachments` | atlassian | files: name, type, size, download URL | `page_id` |
| `confluence_advanced_search` | mirror | the reader UI's advanced form | `q`, `phrase`, `any`, `none`, `space(s)`, `label`, `type`, `creator`, `ancestor`, `updated`, `from`, `to`, `sort`, `limit`, `start` |
| `confluence_get_page_ancestors` | mirror | the trail down to a page, root first | `page_id` |
| `confluence_get_page_descendants` | mirror | every page below a page, level by level, a window at a time | `page_id`, `start`, `limit` |
| `confluence_get_backlinks` | mirror | pages linking to a page | `page_id`, `limit` |
| `confluence_list_spaces` | mirror | the spaces the reader may read | `query`, `limit` |
| `confluence_get_space` | mirror | one space: description, home page, readable count | `space_key` |
| `confluence_list_blog_posts` | mirror | a space's news, newest first | `space_key`, `limit` |
| `confluence_get_recent_changes` | mirror | content whose Confluence timestamp is newest — **not** the ingestion order | `space_key` (optional), `limit` |
| `confluence_index_status` | mirror | **administrators only**: the last spaces indexed, when each was read, recent sync runs | `space_key` (optional), `limit`, `runs` |

Two tools sound alike and are not. `confluence_get_recent_changes` answers "what
changed upstream lately" from Confluence's own timestamps; `confluence_index_status`
answers "what did the mirror ingest, and when" and is administrator material, like
`/admin` — a reader's token gets a tool error, not the sync history.

```
@confluence-mirror what are the last spaces indexed?
→ confluence_index_status
```

`page_id` and `parent_id` accept a Confluence content id **or** a page URL
(`/spaces/ENG/pages/1002/Title`, `?pageId=1002`). Tiny links (`/wiki/x/N4CIO`) need the
site's redirect table and are refused.

Results are `content: [{type: "text"}]` plus `structuredContent` (ids, titles, URLs) —
text for the model, structure for a programmatic client. A tool that fails answers
`isError: true` with a readable message; an unknown tool is a JSON-RPC `-32602`.

## Markdown

`confluence_get_page` renders Markdown from Confluence's `export_view` body with
`Export.Markdown` — the same converter the `.md` download uses. The conversion is cached
(`ConfluencePhxMirror.Mcp.Markdown`, Cachex: 10 000 entries, 12 h) under the page's id
and a digest of its body: a sync that stores a new body simply misses, so there is no
invalidation to get wrong.

## Claude Desktop

Via [`mcp-remote`](https://www.npmjs.com/package/mcp-remote), which runs the browser
flow on first use:

```json
{
  "mcpServers": {
    "confluence-mirror": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://your-mirror-url/api/mcp"]
    }
  }
}
```

## Relationship to mcp-atlassian

The seven `atlassian` tools above are interchangeable with
[`sooperset/mcp-atlassian`](https://github.com/sooperset/mcp-atlassian)'s Confluence
toolset — same names, same arguments — so prompts and habits carry over. The eight
`mirror` tools are read-only navigation the mirror adds; point a client at this server
and they appear alongside the portable ones.

Differences, all of them deliberate:

* **read-only.** `confluence_create_page`, `confluence_update_page`,
  `confluence_add_comment`, attachment upload and the restriction tools do not exist
  here — calling one is an unknown tool. A mirror has one writer: the sync.
* **no history.** The mirror keeps the current version of a page, so
  `confluence_get_page_history`, `…_diff` and `…_get_page_views` are absent.
* **the mirror is a snapshot.** `updated` is Confluence's timestamp, not the sync's;
  the admin dashboard shows when the snapshot was last refreshed.
* **no Confluence macro round-trip claims.** `convert_to_markdown: false` returns the
  stored storage format verbatim; macros the mirror does not render were never stored.
