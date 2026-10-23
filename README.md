# Confluence Mirror

A production-shaped, **read-only** mirror of Confluence built with Phoenix 1.8,
LiveView 1.2, Ecto/Postgres and Elixir 1.20.

It keeps Confluence's own `export_view` rendering (so macros look right),
rewrites internal links so mirrored pages cross-link each other, serves
attachments from a path-based blob store, indexes everything with Postgres
full-text search behind a CQL subset, and keeps two logs: an audit log of
decisions and a live log of what each sync is doing.

![A mirrored page: the space's page tree, the page with its metadata, and the rail with its ids, version and upstream link](docs/images/reader.png)

*One mirrored page: the branch of its space on the left, Confluence's own
rendering in the middle, and a rail naming the Confluence id, version, author
and the original URL.*

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

## What you need

* **Elixir 1.20 or newer** — `mix.exs` requires `~> 1.20`, and the `Dockerfile`
  builds on `elixir:1.20-alpine`; the tests are run on Elixir 1.20.4/OTP 29.
* **Node.js with npm** — `mix setup` installs the browser dependencies with
  `npm ci` in `assets/`; a missing `node` is what stops a first run.
* **Postgres 12 or newer** — the search index is a stored generated column.
  `docker compose` provides one locally; anywhere else it is `DATABASE_URL`.

## Quick start

Three commands look alike and are not, so pick by intent: `mix setup` is the
one-off for a fresh checkout, `mix ecto.setup` builds *only* a database (what a
second source needs), and `mix ecto.reset` drops that database first.

```bash
docker compose up -d          # Postgres, Adminer, smtp4dev (local only)
mix setup                     # first run: deps, database, migrations, assets, first sync
```

### Mirroring a real site

Three variables are the whole contract: the site URL, and the e-mail and API
token of an Atlassian account with Confluence access (create one at
<https://id.atlassian.com/manage-profile/security/api-tokens>):

```bash
export CM_CONFLUENCE_SITE=https://acme.atlassian.net   # "/wiki" optional
export CM_ATL_EMAIL=you@acme.com
export CM_ATL_TOKEN=...
export CM_SPACES=ENG,PROD        # optional; default is every visible space

mix ecto.setup                   # create this site's database, migrate, sync once
mix phx.server
```

`ecto.setup` takes the first snapshot because the scheduler's first pull is a
whole interval away (`CM_SYNC_INTERVAL_SECONDS`, `3600` by default; `0` turns
scheduled pulls off) — an empty mirror would otherwise stay empty for an hour.
Without `ecto.setup`, `mix ecto.create && mix ecto.migrate_all` plus
`mix confluence.sync` does the same in two steps, and the dashboard's sync
button does it again later. `mix confluence.probe` checks the site and the
credentials first; `mix confluence.sync --mode space --space ENG` re-pulls one
space, `--mode snapshot` re-reads everything.

Other knobs worth knowing: `CM_REQUESTS_PER_SECOND=5` and `CM_BURST=5` (the
client's token bucket), `CM_SYNC_CONCURRENCY=4` (changed pages detailed at
once), `PORT=4000`. The exhaustive list is in
[configuration.md](docs/configuration.md).

### Demo snapshot

Unset `CM_CONFLUENCE_SITE` (or set `CM_SOURCE=demo`) and the mirror serves the
bundled snapshot instead of calling out to anything:

```bash
mix setup                # or just `mix ecto.setup` once deps and assets are in place
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

### Switching modes, dropping content

In development each source gets its own database, named after it —
`confluence_phx_mirror_dev_demo`, `..._dev_synthetic`, `..._dev_acme_atlassian_net`
— so switching is only a matter of changing the environment and running
`mix ecto.setup` once for the new one. Nothing is purged, and the previous
mode's mirror is still there when you switch back. Because the name is derived
from the environment, dropping and recreating works the same way — with the
environment that names that database:

```bash
CM_SOURCE=demo mix ecto.reset                             # demo back to a clean snapshot
CM_SOURCE=http CM_CONFLUENCE_SITE=https://acme.atlassian.net mix ecto.drop
CM_SOURCE=http CM_CONFLUENCE_SITE=https://acme.atlassian.net mix ecto.setup
CM_SOURCE=synthetic CM_SYNTHETIC_SPACES=200 CM_SYNTHETIC_PAGES=500 mix ecto.reset
```

`synthetic` is generated content for measuring the reader UI; see
[configuration.md](docs/configuration.md#source-and-sync).

The demo above is the local, self-contained one; none of this is the deployment
model. The app is a 12-factor release — configuration comes from the environment
and any process manager that can run `bin/confluence_phx_mirror` works (a
release that mirrors a real site refuses to start with the sign-in-free
identity switches on). See [operations.md](docs/operations.md) and
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

