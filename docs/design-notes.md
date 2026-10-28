# Why the mirror is built this way

Design decisions worth not re-litigating, and the edges the mirror deliberately
does not cover.

## In one minute

| Decision | Instead of | Why |
| --- | --- | --- |
| store Confluence's `export_view` | re-implementing macros from `storage` | fidelity for free |
| key pages by `confluence_id` + version | keying by path | slugs are cosmetic; mirrors move |
| resolve live macros at sync time | resolving them in the browser | a read-only mirror has no client and no second writer |
| a failing page marks the run `partial` | aborting the run | nothing is silently lost |
| an empty listing keeps the pages | trusting it | a token that lost a permission is not a deletion |
| truncate the sidebar trail per level | drawing the whole tree | the tree grows with the space, the trail does not |
| cache totals per content version | counting per request | a scan per request is what a million pages cannot afford |
| announce a changed page, never swap it | reloading the tab | the reader decides when to move |

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
* `include`, `excerpt` and `excerpt-include` are *not* resolved. The mirror
  shows what `export_view` already carries for them and does not re-check who
  may read the other page: the rule above governs listings the sync builds, not
  bodies it forwards. If `export_view` has inlined another page's content, this
  page hands it to every reader who may open this page.

The alternatives from the Confluence world do not apply here: Confluence fires
`page_updated` only for the page that was edited (not for pages that display its
labels), resolve-macros-in-the-browser needs a client, and write-back/re-caching
pipelines need write access we deliberately do not have. Resolving from the
mirrored data at sync time is the read-only equivalent.

## Dynamic content: one renderer per macro

A macro is a marker in the body — `<div class="mirror-macro" data-macro="toc">`
— and a module that answers it:

| Piece | What it is |
| --- | --- |
| `Sync.DynamicContent` | finds the markers, reads the body's headings, dispatches, serialises |
| `Sync.DynamicContent.Renderer` | the behaviour: `render(attrs, context)` returns HTML nodes |
| `Sync.DynamicContent.Registry` | the one list mapping a `data-macro` name to its module |
| `Sync.DynamicContent.Context` | the page, its space, its headings, and the content port |
| `Sync.DynamicContent.Source` | the port through which a macro reads the mirror, already narrowed to what the host page's readers may open |
| `Sync.DynamicContent.Nodes` | the HTML vocabulary the macros share |

Macros are **in-tree, not a plugin host**: a renderer is an ordinary module with
an ordinary test (`test/support/stub_content.ex` stands in for the database), and
the registry is a compile-time map, so what the mirror can draw is readable in
one place and dialyzer sees it.

The audience rule lives in the port, not in each macro. Confluence resolves a
macro per viewer; a mirror resolves it once at sync time and bakes one answer
into the page for everybody, so everything a macro lists must be at least as
wide as the page listing it. Applying that once in
`Sync.DynamicContent.Source.Mirror` means a macro written next year inherits it.

Resolved today: `content-by-label`, `page-properties-report` (Confluence's key is
`detailssummary`), `toc` and `children`. What is left falls into three buckets,
and only the first is a mirroring problem:

| Macro | Data it needs | Where it comes from |
| --- | --- | --- |
| `pagetree` | the page tree, below one root | `pages.ancestors` (`Mirror.descendants/2`) |
| `recently-updated`, `blog-posts` | page metadata, optionally filtered | `external_updated_at`, `type` — or a CQL query (see [configuration.md](configuration.md)) |
| `attachments` | the page's files | `attachments` + blob store |
| `excerpt`, `excerpt-include`, `include` | another page's body | `pages.body_export` |
| `contributors` | authors and versions | `author_name` (one author today) |
| `tasks-report-macro` | inline tasks | inline tasks in `body_export` |
| `jira`, `jiraissues`, `jirachart` | issue data | needs Jira credentials: out of scope |
| `livesearch`, `gadget`, `widget` | a client, or a third-party app | impossible statically |
| Forge/Connect app macros | the app | a placeholder is the honest answer, and the body is kept |

The order to implement them is by value per line: `include`/`excerpt-include`
(pages that build other pages), then `recently-updated`, then `attachments`.
Each is one module and one line in the registry; nothing else changes.

### Vendor macros: extensions, one file per app

The marketplace's layout macros are a different shape of problem. Their content
is *on the page* — a tab group wraps its tabs, a card grid wraps its cards — so
they need no app and no query, only the knowledge of what the wrapper means.
They live in `Sync.VendorMacros`, one module per vendor, registered by their own
`ac:name`:

| Vendor | Keys | Drawn as |
| --- | --- | --- |
| Seibert Media (Aura) | `aura-tab-group`, `aura-tab`, `aura-cards`, `aura-title`, `aura-progress-bar`, `aura-countdown` | `<details>` per tab, a grid, a heading, a bar with its value; the countdown keeps its date and says it cannot tick |
| Karma | `karma-section`, `karma-row`, `karma-column` | `div`s that keep their children in order |
| Adaptavist | `tabs`, `tab`, `tooltip`, `latex-block` | `<details>`, a `title` attribute, and a LaTeX block that shows its source and says so |

**Not drawn, on purpose:** `table-filter`, `pivot-table`, `chart-from-table`,
`table-exporter`, `forms-by-adaptavist`, `confiform-*`. The first four exist to
run a query or a UI over a table a reader can already see; the last two are
writable forms with a backend. A static mirror that invented an answer would be
lying about the source, so they fall back to `Sync.Renderer`, which **keeps the
macro's body** and says what the macro was — a vendor macro is usually a
container, and dropping its body would lose the page somebody wrote.

## Space and site customisation

Confluence lets a site and a space look different; a mirror that ignores this
looks like a different product:

| Piece | State |
| --- | --- |
| **Space icon** | mirrored: downloaded into the blob store and served at `/spaces/:key/icon`, in the directory and the space header |
| **Space homepage and description** | mirrored (`homepage_id`, description in the space header) |
| **Space categories** | mirrored, from `metadata.labels` with the `team:` prefix |
| **Page cover image** | not implemented — a page property (`cover-picture`) pointing at an attachment |
| **Announcement banner** | not reachable: site-level, and not exposed by the read-only REST API |

Deliberately not mirrored: custom themes and layouts (they only make sense with
the client-side editor), user-generated CSS.

## Identity: one person, several Confluence accounts

The mirror can pre-create accounts from what a sync sees (page bylines and
group membership), but one person often holds two Atlassian accounts — a
personal one and a guest or contractor one — and the content and permissions may
name either. What exists today:

* `users.identity_account_ids` holds the *further* Confluence identities an
  account stands for;
* `User.identity_keys/1` answers with the union — e-mail, the sign-in identity
  and every linked one — so what a reader may open is everything any of their
  identities may open, on every door (session and API token alike);
* `/admin/identities` and `POST /api/v1/identities/:account_id/link` are where an
  administrator links or unlinks one, audited as `user.identity_linked` /
  `user.identity_unlinked`.

Still not built, and the reason: **several e-mail addresses per account**. Today
`users.email` is unique, so one address means one account. The design when it is
needed:

* a `user_emails` table holding `email`, `user_id`, `source`, `verified_at`, with
  the existing `users.email` as the primary address;
* sign-in looks the address up across `user_emails`, so any verified address
  signs into the same identity;
* a signed-in reader may add another address, which receives a magic link;
  confirming it attaches the address. An address another account holds is
  refused, never merged silently;
* pre-created accounts are placeholders with no confirmed address; the first
  successful sign-in confirms the one that was used.

### Who a proxy identity is allowed to be

An OAuth2 proxy answers "who is this?"; it does not answer "should they be
here?". Its user directory is the Atlassian organisation, and a mirror is
usually one site inside it, so trusting the proxy's word would hand the mirror
to everybody in the company. The mirror therefore decides for itself, from what
the sync knows: an administrator (seeded, role, or admin group), or an identity
the sync has read about — a group member, a user named by a space permission or
a page restriction, or the author of a page or a comment
(`Mirror.identity_known?/1`). Anyone else gets a 403 and no account. Authorship
is the one that makes the rule hold: whoever may read on Confluence may read
here, and the content names its authors before any permission does.

The honest limitation: Confluence Cloud has no API that lists a site's users,
so "a user of the site" can only mean "somebody the mirror has evidence of".
A legitimate reader who belongs to no mentioned group and is named in no
permission is indistinguishable from a stranger; the remedy is a group on the
Confluence side, which the next sync then knows.

## What a page view costs

A mirror of a real site has spaces with thousands of pages, and the page view is
the screen opened most. Two decisions follow.

**The sidebar follows the reader.** A page view draws the trail from the space's
root to the page being read — each level with the siblings around it, and the
page's own children — rather than the whole page tree, which grows with the space
and is mostly pages nobody asked for. The trail is bounded per level, the sidebar
says when it was cut short and links to the catalog, and the access filter runs
in the same statement that reads it.

**Totals are computed once per version of the content.** "How many pages does
this space hold" is a scan, and a scan per request is what a million pages cannot
afford. Content only changes through a sync, so `Mirror.Counters` caches the
answer against the newest write in the mirror and recomputes when it moves — no
timer, no staleness window.

Both are held to a query budget by the suite (`QueryBudgetTest` over the demo
snapshot, `ScaleTest` over a thousand spaces of a thousand pages); the numbers
are in [performance.md](performance.md). Search is the one screen whose cost
still grows with the site: ranking a query that matches every page is a pass over
every match, inherent to `ts_rank_cd`.

**A page that changed while it is open is announced, not swapped.** A sync can
write the page under a reader — a webhook delivery, a schedule tick, an
administrator's re-read — and a mirror that reloaded the tab itself would take
the paragraph away mid-sentence. The page carries one more island
(`PageStaleLive`) for this: it subscribes to the page's `PageUpdates` topic,
and a sync announces a page once its transaction has committed. The reader then
gets a small notice in the corner with a reload and a dismiss, and nothing moves
until they take one. The announcement carries the moment the mirror read the
page, so a tab that already shows that copy — opened in the middle of a run —
stays quiet. The island costs no query: everything it needs arrives in its
session.

## Emoticons and comments in search

`export_view` renders an emoticon as an image on the Confluence host, not as its
character: `ac:emoticon` never reaches the mirror, and typed `:)` stays text in
the export. An image on the Confluence host is not loadable by an anonymous
reader of the mirror, so `Sync.Emoticons` replaces the markup with the character
it stands for — the emoji Confluence stored in `data-emoji-fallback` when there
is one, the classic name (`tick`, `smile`, …) otherwise. The page view runs the
same conversion over a stored body, which is why an existing mirror needs no
resync for its emoticons to appear; a body synced after the change is converted
once, at sync time, and its `body_text` carries the character too.

Search reads comments as well as pages. They are indexed by an expression over
`comments.author_name` and `comments.body_text` — both already stored — so
nothing has to be re-read from Confluence for a comment to become findable. A
hit remembers which comment matched, and the screen says so rather than quoting
an unrelated paragraph of the page.

## Known limitations

* Confluence's own emoji set (`:big_grin:`, the blue-star family) has no Unicode
  character — its glyph is a sprite image on Atlassian's side — and `export_view`
  writes the shortcode as *text*, where nothing distinguishes it from prose. The
  **storage** does: it marks the pick as `<ac:emoticon ac:emoji-id="atlassian-big_grin"
  ac:emoji-shortname=":big_grin:" …>`. `Sync.Emoticons.from_storage/2` replaces
  the shortcodes that markup names with the nearest character (`😁`, ⭐, ✅ …),
  and only those: prose and anything inside `<pre>`/`<code>` keeps its text.
  Standard emoji and the classic emoticons carry a fallback character or a
  classic name and need no storage to resolve. A body mirrored before this
  existed gets the characters on its next sync — a page from its own stored
  storage at render time.
* Comments are read-only and rendered flat (one reply level styled).
* Confluence Cloud does not expose *space* permissions for reading, so they are
  mirrored only when a source can supply them; page restrictions are synced.
* A page's body carries the titles of the pages it links to at the moment it was
  synced. Backlinks and outgoing links are computed live from the link table, so
  they never go stale, but link *text* baked into a body does — until that page
  is synced again.
* Space icons are mirrored from the download link Confluence publishes (translated
  into the REST attachment link, which is the one that accepts an API token). A
  personal space's icon is the owner's avatar and Confluence redirects it to
  gravatar, outside the hosts the client may download from, so such a space keeps
  the key tile.
* `include`-family macros are forwarded from `export_view` without an audience
  check (see the dynamic-content section above).
* Live macros that need an Atlassian session (Jira issue detail, user hover
  cards) render as the link/placeholder Confluence puts in `export_view`.
* S3 blob storage is an interface, not an implementation, in this PoC.
