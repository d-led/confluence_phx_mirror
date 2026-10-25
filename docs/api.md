# API and CQL

The mirror exposes three surfaces over the same content: the reader UI, a
first-party JSON API under `/api/v1`, and a Confluence-compatible subset under
`/wiki/rest/api` for tools that already speak Confluence.

A fourth, `/api/mcp`, speaks the Model Context Protocol to AI assistants and
answers with the same authorization as the two APIs — see [mcp.md](mcp.md).

## The description

`/api/openapi.json` is an OpenAPI 3.1 document covering both API surfaces and
`/health`; `/api/docs` renders the same document as a page, so the two cannot
disagree. Neither needs a token and neither touches the database.

`/api/docs/swagger` is the same document in Swagger UI, for clicking through it
and trying requests. It is a page of its own and the only screen that loads
vendor JavaScript (`assets/js/swagger.js`, built by its own esbuild profile, so
the reader pages never download it). The bundle is served by the mirror, which
is what the `script-src 'self'` policy requires.

The paths come from the router — a new endpoint appears in the document without
anyone remembering to add it — and each one is described in
`ConfluencePhxMirrorWeb.Api.OpenApi`. A test fails when a route has no
description, so the document cannot fall behind the code. Hand the JSON to
Postman, Insomnia or `npx @redocly/cli lint` and it is a complete client.

A release serves all three only with `CM_API_DOCS=1`; development and test serve
them by default. See [configuration.md](configuration.md#api-description).

## Authentication

API tokens are created at **`/profile`** (*API tokens*), shown once and
stored as an **Argon2id** digest in PHC string form (`$argon2id$v=19$m=…,t=…,p=…$…`).
The string carries its own algorithm and parameters, so the policy can be raised
without invalidating issued tokens: a digest written under an older policy is
rewritten the next time the token is used. Only a twelve-character prefix is
kept in clear, as the indexed lookup key — a salted digest cannot be searched by
equality. A token presented from that prefix is then verified against the
digest, which costs about 16 MiB and a few tens of milliseconds per request
(see `ConfluencePhxMirror.Accounts.TokenHash`).

Send either:

```bash
curl -H "Authorization: Bearer $TOKEN" https://mirror.example.com/api/v1/spaces
curl -u "you@acme.com:$TOKEN" https://mirror.example.com/api/v1/spaces
```

`-u` is the Confluence-style Basic form (`base64(email:token)`).

A browser that is already signed in needs no token: the API accepts the same
identity every page does — the mirror's session cookie, and the identity
oauth2-proxy establishes with `CM_PROXY_AUTH` (it forwards the reader in
`X-Forwarded-Email`). That is why `/api/docs/swagger` can call the endpoints
with *Try it out* as whoever opened it; the *Authorize* dialog stays for
scripts, which carry a token instead. In development and test an administrator
is assumed when neither is present, so the demo works with no credentials at
all.

## JSON API

```
GET /api/v1/spaces
GET /api/v1/spaces/:key/pages
GET /api/v1/pages/:id
GET /api/v1/pages/:id/{children,ancestors,descendants,labels,attachments,comments,backlinks}
GET /api/v1/labels
GET /api/v1/search?cql=...
GET /api/v1/stats
GET /api/v1/sync-runs
GET /api/v1/sync-runs/export?format=jsonl
GET /api/v1/identities
POST /api/v1/identities/:account_id/link
DELETE /api/v1/identities/:account_id/link
GET /health
```

`/health` needs no token: it reports the database check, content counters and the
last sync, so it can back a liveness/readiness probe.

`GET /api/v1/pages/:id/descendants` is the pendant to `ancestors`: the whole
branch below a page, transitively, in level order (a page before the pages below
it, siblings by title). A branch can be hundreds of pages, so it is windowed
with `start`/`limit` (default 25, at most 100) and `_links.next` continues; each
result carries `depth` (1 for a direct child) and `parent`, so a window can still
be drawn as a tree. `pages.ancestors` — the trail the sync denormalises onto each
page, GIN-indexed — answers it in one statement, without walking the tree.

`GET /api/v1/search` accepts `q` plus structured filters (`space`, `label`,
`type`, `creator`, `ancestor`, `updated`) for the reader UI, and `cql` for raw
Confluence query language. Default and maximum result counts are
`CM_SEARCH_DEFAULT_LIMIT` (25) and `CM_SEARCH_MAX_RESULTS` (100).

Text search reads pages **and their comments**. A hit that matched in a comment
would otherwise be a page whose snippet has none of the words, so each hit
carries a `comment` — `id`, `author`, `created` — when that is where the words
were, and `null` when the page itself matched. The snippet is the comment's own
text in that case.

### The sync history

A mirror keeps a row per sync run — every schedule tick, every one-page sync an
administrator asked for, every webhook delivery — so the table grows for as long
as the mirror exists. `GET /api/v1/sync-runs?start=&limit=` is one window of it,
newest first, with `total` beside `results` and `_links.next` while there is
more; `limit` defaults to 50 and is capped at 500.

Each run names its `mode` (`snapshot`, `incremental`, `webhook`), its `scope`,
its `status` (`running`, `succeeded`, `partial`, `failed`, `cancelled`), the
times it `startedAt`/`finishedAt`, `durationMs` (`null` while it has not
finished), `cancelRequestedAt`, the counters it wrote in `stats`, and the
`error` the node reported when it broke.

`GET /api/v1/sync-runs/export?format=jsonl` (or `csv`) is the whole history as a
file, oldest first: **JSON lines** keeps each run's `stats` an object, **CSV**
puts it in one cell as JSON. Both are streamed — read in batches as the download
is written — so a hundred thousand runs cost one batch of memory, and a client
that closes the connection stops the work at the next chunk.

Both calls are an **administrator's**: a run's error is what the node said when
the sync broke, which is an operator's reading rather than a reader's. Another
token gets `403 not_authorized`.

### Identities: the only writes

`GET /api/v1/identities?q=&limit=&offset=` lists the Confluence accounts the
mirror knows — the authors of pages and comments, and the account ids the
permissions carry — each with the groups the last sync read and the account it
already stands for (`linkedTo`, or `null`). A site names more people than a page
can draw, so it is searched and windowed like everything else.

`POST /api/v1/identities/:account_id/link` links one to an account:

```json
{"user_id": 4}
```

`email` is accepted instead of `user_id` when the id is not at hand. The answer
is the identity as it now stands beside the account. `DELETE` on the same path
takes it away again.

What the identity carries — its group memberships, the pages and spaces it is
named in — becomes the account's, because every permission rule asks the union
of an account's identities. All three calls are an **administrator's**: another
token gets `403 not_authorized`. The refusals are named rather than swallowed:

| status | `error` | meaning |
| --- | --- | --- |
| 404 | `unknown_identity` | the mirror has read nothing about it — a typo must not become a grant |
| 404 | `not_linked` | nothing stands on it, so there is nothing to take away |
| 409 | `linked_elsewhere` | another account already holds it |
| 409 | `not_a_link` | that is the identity the account signs in with, not a link |
| 422 | `missing_account` | neither `user_id` nor `email` was given |

These are the only writes the v1 API accepts; the rest of the mirror stays
read-only.

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

## What the API does not enforce yet

The v1 API and `/search` still answer from the unfiltered index; the reader UI
routes do apply the permission policy. See
[Known limitations](design-notes.md#known-limitations).
