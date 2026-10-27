# API and CQL

One content store, four surfaces:

| Surface | Path | For |
| --- | --- | --- |
| reader UI | `/`, `/spaces/…`, `/search` | people |
| JSON API | `/api/v1/…` | your own tools |
| Confluence-compatible REST | `/wiki/rest/api/…` | tools that already speak Confluence |
| MCP | `/api/mcp` | AI assistants — see [mcp.md](mcp.md) |

All four answer with the same authorization: a reader never finds in one what
another hides.

## Fast path

```bash
export TOKEN=…                       # /profile → API tokens
curl -H "Authorization: Bearer $TOKEN" https://mirror.example.com/api/v1/spaces
```

The next two sections say who may call, and where the full description lives.

## The document is the spec

Every route, parameter, response shape and status code of both API surfaces is
served by the mirror itself:

| Where | What it is for |
| --- | --- |
| `/api/openapi.json` | OpenAPI 3.1 — Postman, Insomnia, codegen, `npx @redocly/cli lint` |
| `/api/docs` | the same document as a page, server-rendered |
| `/api/docs/swagger` | the same document with *Try it out* |

This page does not copy it, because a copy drifts. The paths come from
`Router.__routes__()`, the descriptions from
`ConfluencePhxMirrorWeb.Api.OpenApi`, and a test fails when a route has no
description — so the served document is the one place that cannot fall behind
the code. None of the three needs a token. A release serves them only with
`CM_API_DOCS=1`; `/api/docs/swagger` is the only screen that loads vendor
JavaScript (its own bundle, so reader pages never download it).

Read it there for what a response contains. What is left on this page is what a
spec cannot say: which credential opens the door, what the two writes refuse,
and how the query language works.

## Authentication

An API token is created by its owner at **`/profile`** (*API tokens*), shown
once, and stored as an Argon2id digest whose prefix is the lookup key — so
raising the hashing policy does not invalidate issued tokens
(`ConfluencePhxMirror.Accounts.TokenHash`).

```bash
curl -H "Authorization: Bearer $TOKEN" https://mirror.example.com/api/v1/spaces
curl -u "you@acme.com:$TOKEN" https://mirror.example.com/api/v1/spaces   # Basic
```

`-u` is the Confluence-style Basic form (`base64(email:token)`).

A browser that is already signed in needs **no token**: the API accepts the same
session cookie and proxy identity every page does, which is why *Try it out*
works on `/api/docs/swagger`. In development and test an administrator is
assumed when neither is present, so the demo needs no credentials at all.

## JSON API

The exhaustive list is in [the served document](#the-document-is-the-spec);
four routes, quoted as examples:

```bash
# a page's branch, windowed with start/limit, `_links.next` while there is more
curl -H "Authorization: Bearer $TOKEN" \
  "https://mirror.example.com/api/v1/pages/1002/descendants?limit=100"

# structured search: one space, one phrase
curl -H "Authorization: Bearer $TOKEN" \
  "https://mirror.example.com/api/v1/search?q=rate+limit&space=ENG"

# the same index as Confluence's own query language
curl -H "Authorization: Bearer $TOKEN" \
  "https://mirror.example.com/api/v1/search?cql=space%20%3D%20ENG%20AND%20label%20%3D%20architecture"

# a page addressed the way a link addresses it: space key plus content id
curl -H "Authorization: Bearer $TOKEN" \
  "https://mirror.example.com/api/v1/page-by-path?space=ENG&id=1002"
```

`/health` needs no token: it checks the database and reports the counters and the
last sync, so it can back a liveness/readiness probe.

`GET /api/v1/pages/:id/descendants` is the pendant of `ancestors`: the whole
branch below a page, level order, windowed. Why it is cheap: `pages.ancestors` —
the trail the sync denormalises onto each page, GIN-indexed — answers it in one
statement, without walking the tree.

### Search hits can come from a comment

Search reads pages **and their comments**. A hit that matched in a comment would
otherwise be a page whose snippet has none of the words, so each hit carries a
`comment` — `id`, `author`, `created` — when that is where the words were, and
`null` when the page itself matched. The snippet is the comment's own text in
that case.

### The sync history

Every run — a schedule tick, a one-page sync an administrator asked for, a webhook
delivery — is a row, so the history grows for as long as the mirror exists:
`start`/`limit` window it, and the export streams all of it as JSON lines or CSV.
Administrator-only, because a run's `error` is what the node said when the sync
broke.

### The two writes, and what they refuse

Everything in the v1 API is a read except two decisions an administrator makes:
linking a Confluence identity to an account, and adding or removing a space key
from the whitelist a run imports. Both are administrator-only; another token gets
`403 not_authorized`.

A refusal names its reason instead of swallowing it. These codes are the part a
generated document cannot enumerate:

| status | `error` | meaning |
| --- | --- | --- |
| 404 | `unknown_identity` | the mirror has read nothing about it — a typo must not become a grant |
| 404 | `not_linked` | nothing stands on it, so there is nothing to take away |
| 409 | `linked_elsewhere` | another account already holds it |
| 409 | `not_a_link` | that is the identity the account signs in with, not a link |
| 409 | `imports_every_space` | this mirror imports every space; narrowing one starts with `CM_SPACES` |
| 422 | `missing_account` | neither `user_id` nor `email` was given |
| 422 | `not_saved` | a space key was missing |

Two consequences of the design, both worth knowing before scripting it:

* **A link carries what the identity carries** — its group memberships, the
  spaces and pages it is named in, the content it authored — because every
  permission rule asks the union of an account's identities
  (`User.identity_keys/1`).
* **Adding a space key only widens.** Removing one trashes what the space holds,
  softly: rows stay, and naming the key again brings them back. A key `CM_SPACES`
  names cannot be removed this way, and the answer says `"removed": false`.

## Confluence-compatible subset

Under `/wiki/rest/api` the mirror answers `space`, `content`,
`content/:id/child/...`, `content/:id/descendant/page`, `content/search` and
`search` with Confluence's envelope: `results`, `start`, `limit`, `size`,
`_links`, plus `body.storage`, `body.export_view` and `metadata.labels`. Point
an existing read-only client at the mirror and its queries keep working.

## Search: CQL on Postgres

```
space = ENG AND label = architecture
text ~ "rate limit" OR title ~ "release"
ancestor = 1000 AND lastmodified > "2026-10-01"
type = blogpost ORDER BY lastmodified DESC LIMIT 10
```

Supported fields: `text`, `title`, `space`, `label`, `type`, `status`,
`creator`, `ancestor`, `parent`, `id`, `version`, `created`, `lastmodified`.
Operators: `=`, `!=`, `~`, `>`, `<`, `>=`, `<=`; `AND`, `OR`, `NOT`, parentheses.

`pages.search_vector` is a **stored generated column** (`title` weighted `A`,
body `B`) with a GIN index; labels and ancestors are `text[]`/`bigint[]` arrays
with GIN indexes, so structured filters never walk the tree. `pg_trgm` backs
typo-tolerant title matching. Comments are indexed too, through an expression
index over their author and body text (see `Mirror.Search`), so `text ~` and the
structured `q` find a page through what a comment says.

There is deliberately no second, trigram index on comment text: two
`CREATE INDEX CONCURRENTLY` builds on one table in a single migration deadlock
against each other. A word *inside* a comment word is therefore not found; word
prefixes are.

The reader UI's LiveView at `/search` compiles the same structured filters to
internal CQL; raw CQL is public only on this Confluence-compatible surface.

## Permissions on every surface

Both APIs apply the same checks as the reader UI — `Authorization.can_read_page?/2`
for one page, `restrict_pages/2` inside a listing query, `readable_results/2`
for a search answer. So:

* a restricted page answers **`404`**, exactly like a page that was never
  mirrored, so an API cannot confirm that content exists;
* a listing (space pages, children, descendants, backlinks, labels, search) is
  narrowed inside its query, so restricted titles never reach the caller;
* `/api/v1/labels` counts pages over what the caller may read, not over the
  whole mirror.

Who may have an account at all is a different question, answered in
[routes-auth.md](routes-auth.md).
