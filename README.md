# Confluence Mirror

A production-shaped, **read-only** mirror of Confluence built with Phoenix 1.8,
LiveView 1.2, Ecto/Postgres and Elixir 1.20.

It keeps Confluence's own `export_view` rendering (so macros look right),
rewrites internal links so mirrored pages cross-link each other, serves
attachments from a path-based blob store, indexes everything with Postgres
full-text search behind a CQL subset, and keeps two logs: an audit log of
decisions and a live log of what each sync is doing.

```
Confluence ──REST──▶ Sync (incremental, rate-limited, audited) ──▶ Postgres (content, links, FTS)
                                    │
                                    ├──▶ blob store (attachments, outside the repo)
                                    ├──▶ mail notifications (smtp4dev in dev)
                                    └──▶ reader UI, REST API, CQL search
```

## What it does

* **Keeps Confluence's own rendering** — pages are stored as sanitised
  `export_view`, so macros look right without re-implementing them; browser-only
  macros are resolved from the mirror's own data or reported as unavailable
  rather than faked.
* **Says whose wiki it is** — the mirror takes the site's name and links every
  page back to the original, so a reader never wonders which Confluence they
  are reading.
* **Pulls only what changed** — scheduled and manual syncs are incremental, and
  a page whose Confluence version is unchanged is not re-rendered or asked for
  its attachments and comments. A snapshot of the live demo site costs about two
  seconds.
* **Stable, Confluence-shaped URLs** — content is keyed by `confluence_id` and
  version, slugs redirect, spaces have home/overview/pages/blog/attachments
  tabs.
* **Mirrored permissions** — page restrictions and (when the source can supply
  them) space permissions are replayed for readers; a hidden page is a `404`.
* **Search that stays in Postgres** — a CQL subset plus structured filters over
  GIN-indexed `tsvector`, arrays and trigrams, with an advanced panel (exact
  phrase, exclusions, contributor, spaces, date range, sort) in the reader UI and
  a REST API beside it.
* **Attachments in a blob store** — path-based keys, atomic writes, never in
  Postgres or `priv/static`.
* **Two logs, for two questions** — the audit log answers "who changed what"
  (accounts, tokens, syncs with their counters and trigger); `/admin/sync-log`
  streams the per-page detail while a sync runs, and the console gets both.
* **Nothing silently lost** — a failing page does not abort a run; it is
  collected, reported, and the run ends `partial` instead of pretending to
  succeed.
* **Read-only by design** — no uploads, no write-back, no page history.

## Documentation

| You are… | Read |
| --- | --- |
| the site administrator: syncing, accounts, permissions, webhooks, skins | [docs/site-admin-guide.md](docs/site-admin-guide.md) |
| deploying and operating it: build, env contract, migrations, monitoring, backups | [docs/operations.md](docs/operations.md) |
| looking for a setting | [docs/configuration.md](docs/configuration.md) |
| integrating: JSON API, Confluence-compatible REST, CQL | [docs/api.md](docs/api.md) |
| working on the code: architecture, tests, quality gates | [docs/developers.md](docs/developers.md) |
| measuring a reader's screens, or load-testing a server | [docs/performance.md](docs/performance.md) |
| wondering why it is built this way, or what it does not do | [docs/design-notes.md](docs/design-notes.md) |

## Quick start (demo snapshot)

```bash
docker compose up -d          # Postgres, Adminer, smtp4dev — local services only
mix setup                     # deps, DB, migrations, assets, demo content
mix phx.server
```

* Mirror: <http://localhost:4000>
* Admin dashboard: <http://localhost:4000/admin>
* Audit log: <http://localhost:4000/admin/audit> · live sync log: <http://localhost:4000/admin/sync-log>
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

## License

Mozilla Public License 2.0 — the full text is in [LICENSE](LICENSE), and
`mix.exs` declares `MPL-2.0` to Hex and tooling.

MPL is file-scoped copyleft: if you distribute a modified version of a file,
that file has to stay under the MPL, while the rest of your system may be under
other terms. Running the mirror as a service is not distribution. Contributions
are accepted under the same licence.

