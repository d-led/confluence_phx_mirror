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

## Quick start

```bash
docker compose up -d          # Postgres, Adminer, smtp4dev
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

## The demo snapshot

`CM_SOURCE` defaults to `demo`: `priv` ships no Confluence content, instead
`ConfluencePhxMirror.Confluence.DemoContent` builds a realistic snapshot in
memory (13 pages/blog posts, nested trees, cross-space links, labels, comments,
attachments, archived pages and the common macros). Everything goes through the
same pipeline as a real site.

* The mirror is **read-only**. Readers cannot edit anything; content only
  changes when a sync pulls a newer snapshot from Confluence.
* Re-run the full pull: `mix confluence.sync`
* Incremental pull: `mix confluence.sync --mode incremental`
* One space: `mix confluence.sync --mode space --space ENG`
* Re-read one page, as a webhook would:
  `mix confluence.webhook --page 1002 --event page_updated`

## Browsing the mirror

The reader UI follows Confluence's entity model instead of one flat page list:

| URL | What it shows |
| --- | --- |
| `/` | home: spaces, recently updated, freshness |
| `/spaces` | space directory with page and blog counts |
| `/spaces/:key` | the space home page (Confluence's space link behaviour) |
| `/spaces/:key/overview` | home teaser, top-level pages, recent, blog, labels, attachments |
| `/spaces/:key/pages` | every page in the space, archived ones included and badged |
| `/spaces/:key/blog` | the space's blog posts |
| `/spaces/:key/blog/:id/:slug` | one blog post, rendered like a page |
| `/spaces/:key/attachments` | all attachments of the space with download links |
| `/spaces/:key/pages/:id/:slug` | one page |
| `/labels`, `/labels/:name` | label catalog and everything carrying one label |
| `/people`, `/people/:account_id` | authors seen on mirrored content |
| `/recent` | newest content across all spaces |
| `/search` | plain-text and structured search |

Archived pages stay readable and searchable — Confluence only hides them from
the page tree, and so does the sidebar here. Blog posts are kept out of the tree
and live under the space's Blog tab.

## What we adopted from the export/backup ecosystem

The design was checked against six Confluence export/backup tools (a Go backup
tool, a C# page-sync CLI, two Python markdown exporters, a JS SDK). The parts
that fit a live, read-only mirror:

* **Identity by Confluence id, not by path** (page-sync CLI) — pages are keyed by
  `confluence_id` and version; slugs are cosmetic and redirect to the canonical
  URL.
* **Page-scoped attachment storage behind a blob store** (markdown exporter and
  backup tool trees) — bytes are keyed by space/page/attachment, never in
  Postgres or the repository.
* **"Nothing silently lost"** (backup tool) — a failing page is recorded in the
  run's errors and the run ends `partial` instead of aborting or pretending to
  succeed.
* **Empty-listing guard** (exporter's zero-pages invariant) — a source that
  suddenly lists no pages for a space never marks that space's content deleted;
  the run is flagged `partial` so an operator looks at it.
* **Rendering fidelity from `export_view`** (markdown exporters re-implement
  macros; we don't) — native `<details>` for expand, panels, lozenges, task
  lists, TOC, gallery and Jira macros come from Confluence's own markup.

Deliberately out of scope: uploads and write-back, page history and templates.
The mirror is read-only and serves Confluence's rendering.

## Dynamic content: macros the browser would normally run

Some Confluence macros (*Content by Label*, *Page Properties Report*, and
anything else driven by a live query) are resolved in the browser, so
`export_view` only carries a placeholder and no amount of HTML mirroring will
fill it in. The mirror resolves them itself, at sync time, from its own
database:

```html
<div class="mirror-macro" data-macro="content-by-label"
     data-labels="runbook,incident" data-match="all" data-limit="10"></div>

<div class="mirror-macro" data-macro="page-properties-report"
     data-space="ENG" data-columns="owner,status"></div>
```

* `content-by-label` runs against the mirror's labels (array containment on
  `pages.labels`, GIN-indexed) and renders a static list of links.
* `page-properties-report` renders a table from `pageproperties` values that
  the sync extracted from each page's storage format into `page_properties`.
* The marker element stays in the body and only its children are replaced, so
  expanding is idempotent. After a page sync (webhook included) every page
  carrying a marker is re-expanded from the database, which keeps listings and
  reports current without a dependency graph, a queue or recursion.
* The resolved content is ordinary HTML: it is searchable, printable and part
  of the page's plain text. Unsupported macros render a short notice instead of
  disappearing silently.

The alternatives from the Confluence world do not apply here: Confluence fires
`page_updated` only for the page that was edited (not for pages that display its
labels), resolve-macros-in-the-browser needs a client, and write-back/re-caching
pipelines need write access we deliberately do not have. Resolving from the
mirrored data at sync time is the read-only equivalent.

## Branding and skins

Readers pick a skin in the header; the choice is a cookie, so the first paint is
already correct and no JavaScript is involved. Four skins ship with the mirror:
`system` (follows the OS), `light`, `mirror` (Atlassian-inspired) and `dark`.

Site authors add their own skin in config — no CSS edit, no asset rebuild:

```elixir
# config/runtime.exs (or config/dev.exs)
config :confluence_phx_mirror, :skins, [
  %{
    name: "acme",                 # cookie-safe: a-z, 0-9 and dashes
    label: "Acme",                # shown in the picker
    icon: "hero-building-office", # any hero- icon
    scheme: :light,               # :dark also switches native controls and code colours
    colors: %{
      base_100: "#ffffff", base_200: "#f2f6ff", base_300: "#d3deef",
      base_content: "#11213d",
      primary: "#0b5fff", primary_content: "#ffffff",
      secondary: "#3d5afe", accent: "#00a3bf"
    },
    radius: %{box: "0.75rem", field: "0.375rem"}
  }
]
```

The palette is emitted as a `[data-theme="acme"]` rule per request and every
daisyUI component reads its colours from those variables, so buttons, panels
and the Confluence content pick it up immediately. Supported keys are the
daisyUI colour names (`base_*`, `primary`, `secondary`, `accent`, `neutral`,
`info`, `success`, `warning`, `error`, each with `_content`), the three radii,
plus `border`, `depth` and `noise`. Unknown keys and values that are not plain
CSS values are ignored.

For anything a palette cannot express — fonts, spacing, component tweaks — edit
`assets/css/author.css`, which is loaded after the main stylesheet. Scope rules
to `[data-theme="acme"]` so they only affect that skin. A brand-new *built-in*
skin (shipped in the compiled CSS) is a `@plugin "daisyui/packages/bundle/daisyui-theme"`
block in `assets/css/app.css`, next to `light`, `mirror` and `dark`.

`config/dev.exs` declares an example `acme` skin so the mechanism is visible in
development; remove it or replace it with your own.

## Mirroring a real Confluence site

Create an Atlassian API token with access to Confluence, then:

```bash
export CM_SOURCE=http
export CM_CONFLUENCE_SITE=https://acme.atlassian.net
export CM_ATL_EMAIL=you@acme.com
export CM_ATL_TOKEN=...
export CM_SPACES=ENG,PROD          # optional; default is all visible spaces

mix confluence.probe               # verifies URL + credentials
mix confluence.sync                # full snapshot
mix phx.server
```

`mix confluence.probe` prints the account behind the token. A `403 caller cannot
access Confluence` means that account has no Confluence product access on the
site (common with Jira-only accounts); `401` means the e-mail/token pair is wrong.

The client:

* fetches `body.storage` **and** `body.export_view`, version, ancestors, labels,
  comments and attachments;
* is limited by `CM_REQUESTS_PER_SECOND` / `CM_BURST` (token bucket), retries
  `429`/`5xx` with backoff, and never follows redirects;
* only ever talks to the configured host (`SafeURL`), with response size caps;
* supports `CM_SYNC_INTERVAL_SECONDS` for scheduled snapshot pulls.

## Architecture

| Layer | Module | Notes |
|---|---|---|
| Source | `Confluence.Source` | Behaviour; `HttpSource` (REST) and `DemoSource` |
| Ingestion | `Sync` | snapshot / incremental / space / page; per-page error isolation |
| Rendering | `Sync.Renderer` | keeps `export_view`, rewrites links, sanitises, converts expand macros to native `<details>` |
| Content | `Mirror` | Ecto queries for pages, trees, backlinks, labels |
| Search | `Mirror.Search` + `Mirror.Search.CQL` | CQL → parameterised SQL over `tsvector` |
| Blobs | `Blobs.Store` / `Blobs.LocalStore` | path-based; S3 can implement the behaviour |
| Jobs | Oban | `Sync.SnapshotWorker`, `Sync.PageWorker`, notification workers |
| Web | controllers + LiveView | reader UI, admin dashboard, REST API, webhooks |
| Accounts | `Accounts` | magic links, API tokens, Phoenix 1.8 `Scope` |
| Audit | `Audit` | append-only; syncs, webhooks, accounts, attachments |

### Sync semantics

A sync is recorded as a `SyncRun` (`running` → `succeeded` / `partial` /
`failed`) with counters and errors. Failures are **per page**: one broken
attachment or comment does not abort the run. Pages missing from a snapshot are
marked deleted (rows are kept for audit), attachments removed in Confluence are
deleted from Postgres and the blob store.

Snapshots upsert all pages first, then render, so cross-space links resolve even
when the target space appears later in the same run.

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

The web search is a LiveView at `/search`; the same query is available at
`GET /api/v1/search?cql=…`.

## Attachments and the blob store

Attachment bytes are **never** stored in Postgres or under `priv/static`.

```
var/mirror/spaces/ENG/pages/1002/attachments/9001/diagram.svg
```

* Root: `var/mirror` (gitignored) or `MIRROR_BLOB_ROOT`.
* Keys: space → page → attachment id → sanitised filename (traversal-proof).
* Writes are atomic (temp file + rename).
* Served by `AttachmentController` with media type, ETag and
  `Content-Disposition`; inline for images/PDF/text, download otherwise.
* `Blobs.Store` is a behaviour, so an S3 implementation is a drop-in.

## Permissions

Access is mirrored, not invented. Confluence decides who may read a page; the
mirror replays that decision:

* **Page restrictions** are read per page
  (`GET /content/{id}/restriction/byOperation/read`) and stored in
  `page_restrictions`. A restricted page is readable only by the listed users
  and groups.
* **Space permissions** are stored in `space_permissions`. Confluence Cloud
  exposes them as *writes only* (`POST`/`DELETE /space/{key}/permission`), so a
  source that cannot read them says `{:error, :not_supported}` and the space
  stays open — the mirror already shows what the sync account can read.
* **A space without rows is open.** Restrictions narrow; they never widen.
* Mirror administrators always see everything.

Readers are matched on e-mail or Confluence account id (`users.groups`,
`users.confluence_account_id`); group names are the mirrored groups. The
decision lives in `ConfluencePhxMirror.Authorization`, a pure function of the
scope and the mirror's tables:

```elixir
Authorization.can_read_space?(scope, space)
Authorization.can_read_page?(scope, page)
Authorization.visible_spaces(scope, spaces)
```

The reader UI uses it for the space directory, the global space menu, page and
blog views, label/recent listings, attachment downloads and exports; a hidden
resource is a `404`, never a `403`, so the mirror does not confirm what it
withholds.

Not wired yet: the v1 JSON API and the `/search` LiveView still answer from the
unfiltered index. That is the next use of the same policy call.

## Webhooks

Confluence → `POST /webhooks/confluence` with an HMAC-SHA256 signature over the
**raw** body (`X-Hub-Signature-256`). Every delivery is stored (valid or not)
and audited; valid page events enqueue a page sync, removal events mark the page
deleted immediately. Jobs for the same page are coalesced for a minute.

Senders that cannot sign a body can present a fixed token instead. Tokens are
configured per receiver and are only accepted on the webhook route — they never
open the API or the reader UI:

```bash
# CM_WEBHOOK_TOKENS="confluence=s3cret,backup=other-secret"
curl -X POST http://localhost:4000/webhooks/confluence \
  -H 'X-Webhook-Token: s3cret' -H 'Content-Type: application/json' \
  -d '{"event":"page_updated","page":{"id":"1002"}}'
```

With no token configured the plug does nothing and the signature is the only
check; with a token configured either the token or a valid signature is accepted.

```bash
export CM_WEBHOOK_SECRET=change-me
mix confluence.webhook --page 1002 --event page_updated
mix confluence.webhook --page 1002 --event page_removed
```

Without `CM_WEBHOOK_SECRET` the endpoint returns `503` and records the rejected
delivery.

## Notifications

Readers can watch a page or a whole space from the page rail.

* `instant` – one e-mail per changed page (Oban retries, outbox row with
  delivery status);
* `daily` – rolled up by `Notifications.DigestWorker` at
  `MIRROR_DIGEST_HOUR_UTC`.

Development uses smtp4dev: SMTP on `localhost:2525`, web UI on
<http://localhost:3001>. `config/test.exs` uses Swoosh's test adapter.

## Accounts and API

* Development/test: admin is assumed.
* Production: magic-link sign-in (single-use, 15 minutes, self sign-up
  controlled by `MIRROR_SELF_SIGNUP`).
* API tokens: admin → *Users & tokens*; shown once, stored as SHA-256 hashes.
* `Authorization: Bearer <token>` or Confluence-style Basic
  `base64(email:token)`.

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

A Confluence-compatible subset lives under `/wiki/rest/api` (`space`, `content`,
`content/:id/child/...`, `content/search`, `search`) with `results`, `start`,
`limit`, `size`, `_links`, `body.storage`, `body.export_view` and
`metadata.labels`.

## Rate limiting

* **Client → Confluence**: `CM_REQUESTS_PER_SECOND` and `CM_BURST` (token
  bucket shared by all syncs).
* **Reader → mirror**: `CM_READER_RATE_LIMIT_PER_MINUTE` (HTML, API and
  attachments get separate budgets, overridable with
  `CM_RATE_LIMIT_HTML_PER_MINUTE`, `CM_RATE_LIMIT_API_PER_MINUTE`,
  `CM_RATE_LIMIT_ATTACHMENTS_PER_MINUTE`). Responses carry `X-RateLimit-Limit`
  and `X-RateLimit-Remaining`; rejections are `429` with `Retry-After`.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `CM_SOURCE` | `demo` | `demo` or `http` |
| `CM_CONFLUENCE_SITE` | – | `https://acme.atlassian.net` (with or without `/wiki`) |
| `CM_ATL_EMAIL` / `CM_ATL_TOKEN` | – | API credentials |
| `CM_SPACES` | all | comma-separated space keys |
| `CM_REQUESTS_PER_SECOND` / `CM_BURST` | `5` / `5` | client rate limit |
| `CM_HTTP_RETRIES` | `3` | attempts per Confluence request |
| `CM_HTTP_PAGE_SIZE` | `50` | content page size when paginating |
| `CM_HTTP_RETRY_BACKOFF_MS` | `250` | first retry delay (doubles per attempt) |
| `CM_SYNC_INTERVAL_SECONDS` | `900` | scheduled snapshot (`0` disables) |
| `CM_SYNC_LOOKBACK_SECONDS` | `3600` | minimum window for an incremental pull |
| `CM_WEBHOOK_SECRET` | – | enables signed webhooks |
| `CM_WEBHOOK_REQUIRE_SIGNATURE` | `true` | reject deliveries without a valid signature |
| `CM_WEBHOOK_TOKENS` | – | `receiver=token,…` route-scoped webhook tokens |
| `CM_LOGIN_TOKEN_MINUTES` | `15` | magic-link lifetime |
| `CM_SEARCH_PAGE_SIZE` | `30` | results per reader search page |
| `CM_SEARCH_DEFAULT_LIMIT` / `CM_SEARCH_MAX_RESULTS` | `25` / `100` | API/CQL default and cap |
| `MIRROR_BLOB_ROOT` | `var/mirror` | blob store root |
| `MIRROR_AUTO_ADMIN` | `false` (dev/test `true`) | assume an admin |
| `MIRROR_SELF_SIGNUP` | `false` | allow magic-link sign-up |
| `MIRROR_NOTIFICATIONS` | `true` | enable e-mail notifications |
| `MIRROR_MAIL_FROM` | `mirror@localhost` | sender address |
| `MIRROR_DIGEST_HOUR_UTC` | `8` | daily digest hour |
| `CM_READER_RATE_LIMIT_PER_MINUTE` | – | enables reader limits (all scopes) |
| `CM_RATE_LIMIT_{HTML,API,ATTACHMENTS}_PER_MINUTE` | derived | per-scope overrides |
| `DATABASE_URL` | – | Postgres (required in prod) |
| `SECRET_KEY_BASE` | – | cookies/sessions (required in prod) |

## Operations

* `/admin` – freshness, sync runs, audit trail, webhook deliveries, manual
  syncs.
* `/admin/users` – accounts, roles, API tokens.
* `/health` – DB check + content counters + last sync.
* `audit_events` – append-only: `sync.started/finished/failed`, `page.*`,
  `attachment.*`, `user.*`, `api_token.*`, `subscription.*`, `webhook.*`.
* `sync_runs.stats` – pages, attachments, comments, links, notifications,
  deletions and per-page errors.

## Migrations

Migrations are split by *when* they may run:

| Directory | Applied | Use for |
| --- | --- | --- |
| `priv/repo/migrations` | on every boot — the container calls `Release.migrate/0` before `start` | additive schema changes that old and new code both tolerate |
| `priv/repo/manual_migrations` | only when an operator asks | slow indexes, destructive changes, data backfills |

```bash
mix ecto.gen.migration --migrations-path=priv/repo/manual_migrations backfill_status
/app/bin/confluence_phx_mirror eval "ConfluencePhxMirror.Release.migrate_manual"
```

Development and test apply both directories (`mix ecto.migrate_all`), which is
what `mix setup` and the `test` alias use.

## Quality

```bash
mix test                 # domain, rendering, search, auth, webhooks, web, presence
mix precommit            # compile --warnings-as-errors, unused deps, format, credo --strict, sobelow, tests
mix format --check-formatted
mix credo --strict
mix sobelow --config     # security pass, about a second
```

Sobelow runs with `skip: true`, so every accepted finding is either a
`# sobelow_skip [...]` comment with its reason at the call site (sanitised HTML,
the parameterised CQL builder, blob keys) or an entry in `.sobelow-skips` for a
reviewed template. Regenerate those entries with
`mix sobelow --config --mark-skip-all` only after reviewing them again. The
reader pipeline answers `Config.CSP` with a real Content-Security-Policy:
scripts only from the mirror itself, inline styles allowed for Confluence's own
markup.

`mix crap` (ex_crap) scores every function by cyclomatic complexity and its test
coverage, so untested complexity becomes a ranked queue instead of a vague
feeling. It needs exported coverage data:

```bash
mix test --cover --export-coverage default
mix crap --verbose      # full table; `mix crap` prints only the offenders
```

`precommit` runs both with a **ratchet** of `--max-score 135`. That number is
today's worst score, not a target: every PR that closes a queue entry lowers it,
nothing is ever allowed to raise it, and the goal is the conventional `30`
(complexity 5 with no tests). The current queue, highest first:

| Score | Function | Why it is worth tests |
| --- | --- | --- |
| 132 | `Confluence.HttpSource.parse_page/2` | the REST → DTO mapping every real mirror depends on |
| 96 | `Web.Admin.UsersLive.handle_event/3` | admin token/role changes |
| 90 | `Mix.Tasks.Confluence.Webhook.run/1` | operator-facing webhook CLI |
| 73 | `Web.SearchLive.chip_label/2` | filter chips shown on every search |
| 72 | `HttpSource.request_json/2`, `request/4` | rate limiting, retries, response caps |
| 58 | `Mirror.Search.comparison/4` | builds the parameterised CQL SQL |
| 56 | `HttpSource.check_size/1`, `public_url/1` | response caps and link rewriting |
| 45 | `Sync.do_run/3` | per-page error isolation |
| 42 | `SafeURL.parse/1`, `Search.sql_operator/1`, `UserSocket.connect/3`, `SubscriptionController.create/2` | security boundary and request plumbing |

Tests are grouped by the question they answer:

| Level | Files | Question |
| --- | --- | --- |
| Feature (`FeatureCase` + `phoenix_test`) | `test/…_web/features/` | can a reader get from A to B? |
| LiveView | `test/…_web/live_views_test.exs` | what happens when a reader interacts? |
| Controller | `test/…_web/controllers/` | what does one request return? |
| API | `test/…_web/api_test.exs` | what does the JSON surface promise? |
| Unit | `test/…/mirror`, `test/…/sync`, `test/…/blobs` | what does a pure module decide? |

Feature tests use `PhoenixTest`, so they do not care whether a page is a
controller or a LiveView: they visit, click, fill and assert the same way a
reader would, and assert on paths and visible text rather than markup.

Tests cover the CQL grammar, the renderer (cross-links, attachments, sanitising,
native expand macros), blob keys/store, full sync + idempotency, updated pages
arriving through a sync, deletions, notifications, magic links, API tokens,
webhook signatures and Presence.

## Known limitations

* Comments are read-only and rendered flat (one reply level styled).
* Confluence Cloud does not expose *space* permissions for reading, so they are
  mirrored only when a source can supply them; page restrictions are synced.
* The JSON API and `/search` do not yet apply the permission policy.
* Live macros that need an Atlassian session (Jira issue detail, user hover
  cards) render as the link/placeholder Confluence puts in `export_view`.
* S3 blob storage is an interface, not an implementation, in this PoC.
