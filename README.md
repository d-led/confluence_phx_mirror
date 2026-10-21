# Confluence Mirror

A production-shaped, **read-only** mirror of Confluence built with Phoenix 1.8,
LiveView 1.2, Ecto/Postgres and Elixir 1.20.

It keeps Confluence's own `export_view` rendering (so macros look right),
rewrites internal links so mirrored pages cross-link each other, serves
attachments from a path-based blob store, indexes everything with Postgres
full-text search behind a CQL subset, and keeps an audit trail of every sync,
webhook and account change.

```
Confluence ──REST──▶ Sync (rate-limited, audited) ──▶ Postgres (content, links, FTS)
                                    │
                                    ├──▶ blob store (attachments, outside the repo)
                                    ├──▶ mail notifications (smtp4dev in dev)
                                    └──▶ reader UI, REST API, CQL search
```

## What it does

* **Keeps Confluence's own rendering** — pages are stored as sanitised
  `export_view`, so macros look right without re-implementing them.
* **Stable, Confluence-shaped URLs** — content is keyed by `confluence_id` and
  version, slugs redirect, spaces have home/overview/pages/blog/attachments
  tabs.
* **Mirrored permissions** — page restrictions and (when the source can supply
  them) space permissions are replayed for readers; a hidden page is a `404`.
* **Search that stays in Postgres** — a CQL subset plus structured filters over
  GIN-indexed `tsvector`, arrays and trigrams, exposed in the reader UI and over
  REST.
* **Attachments in a blob store** — path-based keys, atomic writes, never in
  Postgres or `priv/static`.
* **Nothing silently lost** — every sync is an audited run that can end
  `partial` with per-page errors instead of pretending to succeed.
* **Read-only by design** — no uploads, no write-back, no page history.

## Documentation

| You are… | Read |
| --- | --- |
| the site administrator: syncing, accounts, permissions, webhooks, skins | [docs/site-admin-guide.md](docs/site-admin-guide.md) |
| deploying and operating it: build, env contract, migrations, monitoring, backups | [docs/operations.md](docs/operations.md) |
| looking for a setting | [docs/configuration.md](docs/configuration.md) |
| integrating: JSON API, Confluence-compatible REST, CQL | [docs/api.md](docs/api.md) |
| working on the code: architecture, tests, quality gates | [docs/developers.md](docs/developers.md) |
| wondering why it is built this way, or what it does not do | [docs/design-notes.md](docs/design-notes.md) |

## Quick start (demo snapshot)

```bash
docker compose up -d          # Postgres, Adminer, smtp4dev — local services only
mix setup                     # deps, DB, migrations, assets, demo content
mix phx.server
```

* Mirror: <http://localhost:4000>
* Admin dashboard: <http://localhost:4000/admin>
* Mail sink (smtp4dev): <http://localhost:3001>
* Adminer: <http://localhost:8092>
* LiveDashboard: <http://localhost:4000/dev/dashboard>

Development and test **assume an administrator** (`MIRROR_AUTO_ADMIN`), so no
sign-in is needed there. Reader accounts use passwordless magic links.

This quick start is the local, self-contained demo; it is not the deployment
model. The app is a 12-factor release — configuration comes from the environment
and any process manager that can run `bin/confluence_phx_mirror` works. See
[operations.md](docs/operations.md).

To mirror a real site, follow
[site-admin-guide.md](docs/site-admin-guide.md#point-the-mirror-at-your-site).

## Out of scope

Uploads and write-back, page history and templates. The mirror is read-only and
serves Confluence's rendering. The remaining edges — flat comments, space
permissions on Cloud, unfiltered API search, S3 as an interface only — are in
[known limitations](docs/design-notes.md#known-limitations).

