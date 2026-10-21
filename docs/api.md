# API and CQL

The mirror exposes three surfaces over the same content: the reader UI, a
first-party JSON API under `/api/v1`, and a Confluence-compatible subset under
`/wiki/rest/api` for tools that already speak Confluence.

## Authentication

API tokens are created in the admin dashboard (*Users & tokens*), shown once and
stored as SHA-256 hashes. Send either:

```bash
curl -H "Authorization: Bearer $TOKEN" https://mirror.example.com/api/v1/spaces
curl -u "you@acme.com:$TOKEN" https://mirror.example.com/api/v1/spaces
```

`-u` is the Confluence-style Basic form (`base64(email:token)`).

## JSON API

```
GET /api/v1/spaces
GET /api/v1/spaces/:key/pages
GET /api/v1/pages/:id
GET /api/v1/pages/:id/{children,ancestors,labels,attachments,comments,backlinks}
GET /api/v1/labels
GET /api/v1/search?cql=...
GET /api/v1/stats
GET /health
```

`/health` needs no token: it reports the database check, content counters and the
last sync, so it can back a liveness/readiness probe.

`GET /api/v1/search` accepts `q` plus structured filters (`space`, `label`,
`type`, `creator`, `ancestor`, `updated`) for the reader UI, and `cql` for raw
Confluence query language. Default and maximum result counts are
`CM_SEARCH_DEFAULT_LIMIT` (25) and `CM_SEARCH_MAX_RESULTS` (100).

## Confluence-compatible subset

Under `/wiki/rest/api` the mirror answers `space`, `content`,
`content/:id/child/...`, `content/search` and `search` with Confluence's
envelope: `results`, `start`, `limit`, `size`, `_links`, plus `body.storage`,
`body.export_view` and `metadata.labels`. Point an existing read-only client at
the mirror and its queries keep working.

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
typo-tolerant title matching.

The reader UI's LiveView at `/search` compiles the same structured filters to
internal CQL; raw CQL is public only on this Confluence-compatible surface.

## What the API does not enforce yet

The v1 API and `/search` still answer from the unfiltered index; the reader UI
routes do apply the permission policy. See
[Known limitations](design-notes.md#known-limitations).
