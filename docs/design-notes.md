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

The alternatives from the Confluence world do not apply here: Confluence fires
`page_updated` only for the page that was edited (not for pages that display its
labels), resolve-macros-in-the-browser needs a client, and write-back/re-caching
pipelines need write access we deliberately do not have. Resolving from the
mirrored data at sync time is the read-only equivalent.

## Known limitations

* Comments are read-only and rendered flat (one reply level styled).
* Confluence Cloud does not expose *space* permissions for reading, so they are
  mirrored only when a source can supply them; page restrictions are synced.
* The JSON API and `/search` do not yet apply the permission policy.
* Live macros that need an Atlassian session (Jira issue detail, user hover
  cards) render as the link/placeholder Confluence puts in `export_view`.
* S3 blob storage is an interface, not an implementation, in this PoC.
