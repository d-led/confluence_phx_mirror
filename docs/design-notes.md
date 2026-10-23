# Why the mirror is built this way

Design decisions worth not re-litigating, and the edges the mirror deliberately
does not cover.

## Rendering fidelity comes from `export_view`

Confluence's `body.export_view` is the server-rendered HTML Confluence itself
serves to a browser. The mirror keeps it (sanitised) instead of re-implementing
macros from `body.storage`, which is what the markdown exporters do and where
they lose fidelity. Internal links are rewritten so mirrored pages cross-link
each other; native `<details>` for expand macros, panels, lozenges, task lists,
TOC, gallery and Jira macros come from Confluence's own markup.

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
* Confluence resolves these per viewer; a static mirror resolves them once and
  shows the answer to everyone who opens the page. A listing therefore only
  contributes pages whose audience is at least as wide as the host page's
  (`Authorization.readable_alongside/2`): a page restricted to a group may list
  open pages, and an open page may not name a restricted one. Where Confluence
  would show that title to some readers, the mirror shows it to none.

The alternatives from the Confluence world do not apply here: Confluence fires
`page_updated` only for the page that was edited (not for pages that display its
labels), resolve-macros-in-the-browser needs a client, and write-back/re-caching
pipelines need write access we deliberately do not have. Resolving from the
mirrored data at sync time is the read-only equivalent.

## Dynamic content: the next macros to resolve

Two families are already handled (resolved, or an honest notice). The rest fall
into three buckets, and only the first is a mirroring problem:

| Macro | Data it needs | Where it comes from |
| --- | --- | --- |
| `toc` | the page's own headings | the rendered body (ids already exist) |
| `children`, `pagetree` | the page tree | `pages.parent_id`, `ancestors` |
| `recently-updated`, `blog-posts` | page metadata | `external_updated_at`, `type` |
| `attachments` | the page's files | `attachments` + blob store |
| `excerpt`, `excerpt-include`, `include` | another page's body | `pages.body_export` |
| `contributors` | authors and versions | `author_name` (one author today) |
| `tasks-report` | inline tasks | inline tasks in `body_export` |
| `jira`, `jiraissues`, `jirachart` | issue data | needs Jira credentials: out of scope |
| `livesearch`, `gadget`, `widget` | a client, or a third-party app | impossible statically |
| Forge/Connect app macros | the app | a placeholder is the honest answer |

The order to implement them is by value per line: `toc` and `children` first (a
page tree is what a reader navigates by), then `include`/`excerpt-include`
(pages that build other pages), then `recently-updated`. Each is a resolver in
`Sync.DynamicContent` keyed by `data-macro`, so they follow the same idempotent
expansion the two existing ones use and need no new plumbing.

## Space and site customisation

Confluence lets a site and a space look different; a mirror that ignores this
looks like a different product:

* **Space icon** — `space.icon` from the REST API, an attachment in the space's
  own storage. The mirror already downloads attachments, so the icon can be
  mirrored like any other file and shown in the space header and the space
  picker. Not implemented yet.
* **Space homepage and description** — already mirrored (`homepage_id`,
  description in the space header).
* **Page cover image** — a page property (`cover-picture`) pointing at an
  attachment; rendered as a banner above the title. Not implemented yet.
* **Announcement banner** — site-level, and not exposed by the public REST API
  for a read-only integration; a mirror cannot show what it cannot fetch.

Deliberately not mirrored: custom themes and layouts (they only make sense with
the client-side editor), user-generated CSS.

## Identity: one person, several sign-in addresses

The mirror can pre-create accounts from what a sync sees (page bylines and
group membership), but one person may arrive with several addresses — a Google
account one day, a GitHub account the next. Confluence itself models this as an
account id with one or more verified e-mail addresses.

The plan, when it is built:

* `users` keeps the identity (display name, role, groups, Confluence account
  id); a new `user_emails` table holds `email`, `user_id`, `source`, `verified_at`.
  The existing `users.email` becomes the primary address.
* Sign-in looks the address up across `user_emails`, so any verified address
  signs you into the same identity.
* Linking: a signed-in reader may add another address, which receives a magic
  link; confirming it attaches the address to their identity. An address that
  already belongs to another account is refused, never merged silently.
* Pre-created accounts (from bylines or group membership) are placeholders with
  no address confirmed yet; the first successful sign-in confirms the address
  that was used.

Until then, one address per account, as `users.email` is unique today.

## What a page view costs

A mirror of a real site has spaces with thousands of pages, and the reader's
page view is the screen that is opened most. Two decisions follow from that.

**The sidebar follows the reader.** A page view draws the trail from the space's
root to the page being read — each level with its siblings, and the page's own
children — instead of the whole page tree. The whole tree is a query over the
space, and it grows with the space: at a thousand pages per space it was a
thousand links and about half a megabyte of response on every page, for pages
the reader had not asked for. The trail is bounded per level (fifteen siblings
around the reader's position) and the sidebar says when it has been cut short,
linking to the space's catalog, which filters and pages in the database. The
sidebar is also filtered in the same statement that reads it, so a page the
reader may not open never appears.

**Totals are computed once per version of the content.** The home page says how
many pages the mirror holds and how many each space has; that is a scan, and a
scan per request is what a million pages cannot afford. Content only changes
through a sync, so `Mirror.Counters` remembers the answer against the newest
write in the mirror (`max(pages.id)`, `max(pages.updated_at)` — two index
probes) and recomputes when it moves. No timer, no staleness window: a sync is
visible on the next request.

Both are held to a query budget by the suite — `QueryBudgetTest` over the demo
snapshot, and `ScaleTest` (opt-in, see [developers.md](developers.md)) over a
generated mirror of a thousand spaces of a thousand pages. Measured there, warm:

| screen | statements | response | median |
| --- | --- | --- | --- |
| a page view | 16 | 48 KB | 3.9 ms |
| a space overview | 13 | 35 KB | 4.4 ms |
| a space catalog | 11 | 80 KB | 4.6 ms |
| the home page | 15 | 36 KB | 6.5 ms |
| search | 18 | 93 KB | 470 ms |

Before the sidebar became a branch, the same page view sent 445 KB and cost
11.5 ms at twenty thousand pages, and would have sent twenty-two megabytes at a
million. Search is the one screen whose cost still grows with the site: ranking
a query that matches every page is a pass over every match, which is inherent to
`ts_rank_cd` and is the next thing to look at. The home page's first view after
a sync pays for the counters' scans once (about seven seconds at a million
pages); a sync now warms them when it finishes, so a reader does not.

## Known limitations

* Comments are read-only and rendered flat (one reply level styled).
* Confluence Cloud does not expose *space* permissions for reading, so they are
  mirrored only when a source can supply them; page restrictions are synced.
* The JSON API and `/search` do not yet apply the permission policy.
* Live macros that need an Atlassian session (Jira issue detail, user hover
  cards) render as the link/placeholder Confluence puts in `export_view`.
* S3 blob storage is an interface, not an implementation, in this PoC.
