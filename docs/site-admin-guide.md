# Site administration

You run the mirror as a product: point it at a Confluence site, keep the content
current, decide who may read what, manage accounts, choose the theme, wire up
webhooks.

| This guide does not cover | Read |
| --- | --- |
| deploying, upgrading, scaling the app | [operations.md](operations.md) |
| every setting | [configuration.md](configuration.md) |
| API consumers | [api.md](api.md) |

## Quick answers

| Question | Where |
| --- | --- |
| How do I point it at my site? | [Point the mirror at your site](#point-the-mirror-at-your-site) |
| How do I refresh the content? | [Pulling content](#pulling-content) · [Keeping it current](#keeping-the-mirror-current) |
| Why is a page missing or empty? | [Troubleshooting](#troubleshooting) |
| How do I let somebody in? | [Who may read what](#who-may-read-what) · [Signing in](#signing-in) |
| How do I keep somebody out? | [Switched-off accounts](#switched-off-accounts) · [Permissions](#permissions-who-may-read-what) |
| Two Atlassian accounts are one person | [Linking an identity](#linking-a-confluence-identity-to-an-account) |
| The site should call us immediately | [Webhooks](#webhooks) |
| The colours are wrong | [Themes and variants](#themes-and-variants) |
| How do I get a copy out? | [Exporting the mirror](#exporting-the-mirror) |
| What does this admin page do? | [The admin area](#the-admin-area) |

## What you need

* A Postgres database the app can reach. In production it is whatever
  `DATABASE_URL` points at; the repository's `docker compose` only provides one
  for local development.
* An Atlassian account with **Confluence product access**, and an API token
  created from <https://id.atlassian.com/manage-profile/security/api-tokens>.

## Point the mirror at your site

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

`CM_SOURCE` picks the source explicitly; left unset, a configured
`CM_CONFLUENCE_SITE` selects the REST client, and with no site at all the mirror
serves a realistic in-memory snapshot — useful to look at the interface before
touching a real site. See [the demo snapshot](#the-demo-snapshot).

## The client is conservative on purpose

The REST client:

* fetches `body.storage` **and** `body.export_view`, version, ancestors, labels,
  comments and attachments;
* is limited by `CM_REQUESTS_PER_SECOND` / `CM_BURST` (token bucket), retries
  `429`/`5xx` with backoff — waiting as long as `Retry-After` asks when
  Confluence names one — and never follows redirects;
* only ever talks to the configured host (`SafeURL`), with response size caps;
* details changed pages `CM_SYNC_CONCURRENCY` at a time, and supports
  `CM_SYNC_INTERVAL_SECONDS` for scheduled pulls (incremental by default).

Each space also brings its **icon**: the uploaded image is downloaded into the
blob store (like an attachment) and served at `/spaces/:key/icon`, so the space
directory and the space page look like Confluence's. Confluence's published icon
path only answers a browser session, so the client translates it into the REST
attachment link that accepts the API token. A space on Confluence's *default*
icon has no image to fetch and is drawn with its key instead. A personal space's
icon is the owner's avatar, which Confluence redirects to gravatar — not one of
the hosts the client may download from — so personal spaces keep the key tile
(they are skipped by default anyway).

A space's **categories** come in with the listing too (`metadata.labels`): the
mirror keeps the `team`-prefixed labels, which are what Confluence shows in the
space directory's *Labels* column, and ignores `global` (labels of the content
inside the space) and `my` (the calling reader's own, such as their star). They
appear as chips beside the space name, in the directory and on the overview.

## Pulling content

```bash
mix confluence.sync                              # incremental pull
mix confluence.sync --mode snapshot              # full re-read of every page
mix confluence.sync --mode space --space ENG     # one space
mix confluence.webhook --page 1002 --event page_updated
```

A sync is recorded as a run (`running` → `succeeded` / `partial` / `failed`)
with counters and errors. Failures are **per page**: one broken attachment or
comment does not abort the run. Pages and blog posts missing from a listing are
**flagged**, not trashed: they keep being served and wait for a person on
`/admin/upstream`, because a listing that leaves a page out cannot tell a
deleted page from one the token may no longer read — see
[the trash](#the-trash). Attachments removed in Confluence are deleted from
Postgres and the blob store. A space missing from a whole-site snapshot is
reported the same way, with the run saying which space it could not find, and
anything that reappears upstream is live again on the next sync.

**Which spaces are imported** is decided by two lists that add up. `CM_SPACES`
is the floor, fixed at boot; the *spaces added at runtime* setting widens it
from `/admin/settings` without a restart. Either naming nothing means every
space, which is how a mirror that was never narrowed behaves. The runtime list
cannot take a key away — a key the environment still names would return at the
next boot, so the screen would be lying about what is in force.

A space that leaves the whitelist is **trashed**, not purged, with its pages and
their comments: rows stay, and naming it again brings it back on the next sync.
So the first key entered on a mirror that was holding everything narrows it to
that key, and the next run trashes the rest — recoverable, but not free. That is
the one removal a sync performs, because it is a decision about configuration
rather than an answer from the site. A source that suddenly lists no spaces, or
no pages for a space, never trashes anything: the run is flagged `partial`
instead.

**Personal spaces are skipped** unless `CM_SYNC_PERSONAL_SPACES=true`. Everyone
on a Confluence site has one (`~accountid`), it holds their drafts, and it is
rarely the site an operator means to publish. The rule holds for every kind of
run — a whole-site snapshot, an incremental pull that happens to find a new page
in someone's private space, a webhook — so the space cannot arrive through the
back door; the run's counters say how many spaces it left out
(`skipped_spaces`) and how many pages (`skipped_personal`). Syncing one space by
key is still a request rather than a discovery: that one is honoured.

Every run also reads the site's **space list** once, whatever mode it is. That is
how a space created outside an incremental run's lookback window arrives at all:
`changed_since` only names pages that moved inside the window, so a space nobody
has listed would otherwise wait for a snapshot nobody knew to run. The same read
finishes a space whose row was created by one changed page and whose listing was
therefore never read — `spaces.pages_listed_at` remembers the last full listing,
and a space is only marked once that listing has landed, so an interrupted run
resumes instead of believing half a space. Its pages arrive with their bodies (a
listing carries them); comments, attachments and restrictions follow through the
detail backlog, so raising `sync.detail_backlog` is what speeds a catch-up. A
space-list read that fails makes the run `partial` rather than quietly short, and
`spaces_discovered` counts what the read added.

A run also settles **who** before **what**: the people it already knows get their
groups read first, then the content, then the groups the content's restrictions
refer to. Confluence never lists its users, so a person the content names for the
first time is picked up at the end of the same run.

### Comments and attachments are content too

Confluence versions each thing separately: a new comment or a replaced
attachment bumps *its* version and never the page's. A run that only asks "which
pages changed since" therefore cannot see either of them, so the mirror asks the
same question of comments and attachments ("what was touched since") and treats
a page whose comment or file changed as a page to re-read — the page's own
version stays exactly what Confluence says it is.

The mirror also keeps track of which pages it has read in full. A page that a
listing introduced but whose details were never fetched is remembered
(`details_synced_at`) and caught up later, at most
`CM_SYNC_DETAIL_BACKLOG` pages per run (default `200`), so the first run after an
upgrade works through a long-standing site without one enormous run. The run's
counters report how many it caught up (`details_caught_up`); those pages count
as unchanged, because their own content did not change.

Neither is a feature of one kind of run. A page's comments and files are read
whenever the page itself is read, in every mode: the first snapshot, the nightly
incremental, a webhook-driven page sync and a single page fetched from
`/admin` alike. The modes differ in *which* pages they read, never in what a read
brings back.

The mirror is **read-only**. Readers cannot edit anything; content only changes
when a sync pulls a newer snapshot.

## Keeping the mirror current

* **How often it pulls** is a setting: *Sync → How often the mirror pulls*
  (`sync.interval_seconds`, `CM_SYNC_INTERVAL_SECONDS` seeds it, default `3600`).
  The clock re-reads it on every tick, so a new cadence needs no release — it
  applies after the tick in flight, and `0` switches the schedule off.
* The **missing-pages check** — the pass that asks every space what it holds,
  which is the only way a page Confluence stopped listing is noticed — has its
  own interval (`sync.reconcile_interval_seconds`), `0` by default, which leaves
  it on the *Run* button at `/admin/upstream`.
* Webhooks react to single changes within seconds — see [Webhooks](#webhooks).
* **Pause Confluence calls** is the button beside *Sync now* on
  `/admin` (or `CM_SYNC_PAUSED` for a deployment that starts paused). It stops
  the mirror reading from the site at all: a run is refused before it starts,
  queued jobs wait (they snooze rather than fail, so a long pause costs no
  attempts), and the space listing is not fetched either. Reader pages keep
  serving what is already mirrored and say so — the footer next to *Last sync*
  reads `· updates paused`, the overview carries the banner with the button that
  resumes, and the screens that would otherwise offer a sync are disabled with
  the reason. This is how one instance can stand down so another (say a
  production mirror) has the API budget.

## The admin area

Everything you need to operate the mirror as a product lives under `/admin`,
split by what each page is for. Every page carries the same sidebar down the
left, grouped into monitoring, content, access and configuration, so you can
move between them without going back to a hub; the page you are on is marked in
it, and on a narrow screen the same list folds into a disclosure naming that
page:

* `/admin` (**live**, refreshes every 5 s) – the overview: freshness, sync runs
  (counters, errors, `running` → `succeeded` / `partial` / `failed`), recent
  activity and recently updated pages, and the manual sync actions: *Sync now*
  (what changed) and *Sync one space*. Under the runs table, where a run's cost
  is on screen, sits "Re-read everything" — the one action here that costs what
  a first sync cost, because it fetches and re-renders every page and
  attachment, changed or not. It says so where it stands, warns that it takes
  hours on a large site, and asks before it queues.

  The runs table is a window of the last eight, because that is what an
  operator can read at a glance; the database keeps every run the mirror ever
  did. The section header carries the way out of the window: **All runs (CSV)**
  for the spreadsheet, **JSONL** for a script. Both stream from Postgres as the
  file downloads, so a hundred thousand runs cost a batch of memory rather than
  a hundred thousand rows, and closing the download stops the reading at the
  next chunk. The same history is on the API — see
  [`/api/v1/sync-runs`](api.md#the-sync-history) — where it is paged instead of
  streamed.
* `/admin/sync-log` (**live**) – the live log: every page, file and call to
  Confluence a sync touches — status, size, latency, retries and the waits the
  client-side rate limiter imposed — plus a summary line when the run ends
  (calls, bytes, retries, throttled time, failures and the answers the site
  gave), held in memory while the run is fresh, with level and text filters.
  Lines can be selected like any text; **Copy** takes the ones on screen, one
  per line, as time, level, line and run. A job's **log** link opens the same
  page narrowed to that job's run (`/admin/sync-log?run=72`), which is a view of
  the one tail rather than a separate log; the chip above the lines says which
  run, and takes the filter off again.
* `/admin/jobs` (**live**, refreshes every 5 s) – what Oban itself holds, in
  every state: waiting, scheduled, retrying, executing, completed, cancelled and
  discarded, with the trigger that asked for each job. It is not a sync screen:
  every background worker the mirror runs appears here, and a feature that adds
  one needs no change to the page. The overview's run list shows only the syncs
  still *waiting*, because a sync that has not started can still be prevented; a
  job that is *executing* belongs here, and that is what makes this page worth
  having after a deploy. A job whose node went away stays `executing` for ever —
  nothing in Oban writes to that row again — so it holds one of the queue's slots
  while being invisible everywhere else. **Stop** cancels any job that has not
  finished, records it in the audit log, and, for one that is really running,
  stops it: what it already wrote stays. A job executing for longer than any sync
  run this mirror has measured is labelled **long-running**, which is a hint for
  the operator, not a diagnosis: only a job that is actually running can tell the
  two apart.

  **Progress** answers "what is this job doing?" from the record the job writes,
  not from a list of known workers: the record's status and colour, one line of
  counters ("120 pages so far", "40 listed · 12 changed"), the reason it failed
  in the tooltip, and a link to its own log. For a sync that record is the run —
  `sync_runs.job_id` says which job wrote it, which is why a page sync's row
  links into the sync log narrowed to that run. A row written before that column
  existed shows a dash: the two records cannot be joined after the fact. A worker
  that keeps no record simply shows a dash too; giving it one is a schema with a
  job id and three one-line functions (`ConfluencePhxMirror.Jobs.Progress`).
* `/admin/webhooks` (**live**, refreshes every 5 s) – what Confluence sent and
  whether its signature checked out, including rejected deliveries, plus
  whether a secret and fixed tokens are configured.
* `/admin/audit` (**live**) – the audit log: decisions and changes (accounts,
  tokens, subscriptions, webhooks) and one entry per sync with its counters and
  what triggered it.
* `/admin/trash` (**live**) – content an administrator moved out of the way:
  trashed spaces with their page counts, and trashed pages and blog posts, each
  with a purge button. "Empty the trash" asks for a second click. Purging is the
  only thing that deletes content by hand, and it takes the comments and
  attachment files with it; a nightly job does the same for what has sat there
  longer than [the holding period](#the-trash).
* `/admin/spaces` (**live**) – which spaces this mirror imports, and which ones
  it could. The keys the environment fixes (`CM_SPACES`) are shown as such; the
  ones added here are removable, and a key the environment names cannot be
  removed — the variable would restore it at the next boot. What is on offer is
  Confluence's own listing, held for ten minutes so the page is not a request
  per render; *Check Confluence* asks again, which is what a space created a
  minute ago needs before it can be picked. A mirror that imports every space
  has nothing to add and says so: narrowing one is a decision about what to stop
  importing, and it starts with `CM_SPACES`. Adding a key widens the next run;
  nothing is removed that way.
* `/admin/users` (**live**) – accounts, roles, mirrored groups and the tokens an
  account has. Tokens are *not* minted here: they belong to their owner and are
  created on [the reader's own account page](#accounts-tokens-and-identities).
  An administrator can still revoke one — revoking only takes access away. Each
  account lists the Confluence identities it stands for, read-only, and points at
  the page where that is changed.
* `/admin/identities` (**live**) – the people Confluence's content names, the
  groups the sync read for each of them, and the account each identity is linked
  to (or that none is). Searching and linking live here; see
  [Linking a Confluence identity to an account](#linking-a-confluence-identity-to-an-account).
* `/admin/permissions` (**live**) – who may read what: the spaces that are
  narrowed, and one space's groups, people and page restrictions behind it. A
  space is its own address (`/admin/permissions/LOAD101`) and so is a page of it
  (`/admin/permissions/LOAD101/pages/42`), so the question can be sent to a
  colleague. Grants and removals made here sit *on top of* what Confluence
  says; see [Permissions: who may read what](#permissions-who-may-read-what).
* `/admin/settings` (**live**) – the setup screen, in two halves. The top is
  what you can change while the mirror runs, one readable list in the order it is
  declared in `ConfluencePhxMirror.Settings.Catalogue`: theme, reading (per-reader
  request limits, search page and result sizes), sync (how often the mirror
  pulls, how often it looks for missing pages, pause, spaces added at runtime,
  pages written at once, the detail backlog, the lookback window, the page size a
  Confluence call asks for), notifications, and operations (sign-in link
  lifetime, personal spaces in a whole-site export, the overview's refresh
  cadence). Each row says what the setting does, what the deployment configured,
  and the variable behind it. A group saves as one transaction: either every
  field of it and its audit entry were stored, or nothing was. A field you leave
  empty means "no decision" — the value this deployment was configured with
  applies again, and the placeholder shows it; *use the deployment's values*
  hands a whole group back.

  The **filter** above the list answers "where do I change this?" — `?q=` in the
  address, so the question can be sent to a colleague and the back button works.
  Every word has to match (`sync pause` finds the switch, `sync theme` finds
  nothing), and a word matches the group, the label, the help, the key and the
  variable, so `CM_SYNC`, `paused` and `interval` all land somewhere. It narrows
  the bottom half too, because half the answer is often "you cannot change this
  here, and here is the variable that does". Rows the filter hides keep their
  fields, so a filtered group still saves every value it is holding.

  The bottom half is what the mirror booted with — source and credentials,
  identity and administrators, webhook and mail delivery, storage and the proxy
  — each row naming the environment variable that changes it, secrets shown as
  *configured* never printed. Those are read at boot: change the variable and
  restart ([themes and variants](#themes-and-variants)).
  [configuration.md](configuration.md#live-settings) lists exactly which
  variables are live and which need a restart. Webhook switches keep their own
  screen (`/admin/webhooks`), where the cost of each is spelled out.
* `/health` – database check, content counters and last sync; no auth, so it
  can back a probe ([operations.md](operations.md)).

Scheduled and manual syncs are **incremental**: the mirror asks Confluence only
for content that changed, and a page whose version is unchanged is not
re-rendered or asked for its attachments and comments. The run's stats say how
much that saved (`unchanged` pages, `attachments_downloaded`).

Pages are written before their bodies: the first pass records every title, tree
position, label and property, and a second pass renders each body at the pace
Confluence allows. Until a page's body arrives it is listed and openable, with a
*Body not mirrored yet* notice instead of an empty article. An interrupted run
leaves those pages where they are; the next run renders whatever is still
missing.

Two tables back the logs and are worth knowing when you query them directly:

* `audit_events` – append-only: `sync.started/finished/failed`, `user.*`,
  `api_token.*`, `subscription.*`, `webhook.*`, `pages.deleted`, and the access
  decisions made on this mirror (`space.access_*`, `page.access_*`).
* `sync_runs.stats` – pages seen and changed, attachments downloaded, comments,
  links, notifications, deletions and per-page errors.

A run that ends `partial` is not a failure: something was skipped and the run's
errors say what. A run that ends `failed` means the source itself was
unreachable or rejected the credentials.

## The trash

A sync never deletes. A page the site's listing stopped naming is **flagged**:
it keeps being served, keeps its comments and files, and waits on
`/admin/upstream` for somebody to look. Only that person moves it to the trash,
where it keeps its rows, its files and its audit trail until it is purged; a
later run that finds the page listed again clears the flag and nothing was lost.

That restraint is deliberate, and it is the answer to the question this mirror
cannot ask Confluence: **is this page gone, or may my token no longer read it?**
A page restriction added for the sync account, or a group it lost, removes pages
from a listing exactly the way a deletion does. Deleting on that evidence would
let a permission change — often a temporary one — wipe the mirror, so the sync
reports what it saw and stops there. Two shapes get their own line in the run's
errors, because they are what a permission change looks like:

| The run says | What it means |
| --- | --- |
| `listing_shrank` | the listing named far fewer pages than the mirror holds |
| `empty_listing_kept_existing_pages` | a space listed nothing at all |
| `not_listed_by_the_source` | a space this mirror holds was absent from the site's space list |

If you see one of those after a token was rotated or a group changed, fix the
access and re-run: the flags clear themselves on the next listing that names the
pages. If the pages really are gone, empty the review list on `/admin/upstream`
and they move to the trash.

Trashing would also mean the mirror grows by everything ever deleted: the rows
*and the attachment bytes*. So a trashed space or page waits a while and is then
purged for good, files included:

* **`trash.retention_days`** (variable `CM_TRASH_RETENTION_DAYS`, default
  `30`) is how long the holding period is. It is on `/admin/settings` under
  *Operations*, next to the sign-in link lifetime and the overview's refresh
  cadence, and it is the same number the trash screen uses.
* A job runs once a night at 03:30 UTC and removes exactly what is older than
the period — never anything younger, never anything still published.
* `0` switches the nightly job off. The trash then keeps everything until
somebody empties it on `/admin/trash`, which is what a mirror of an archive you
want complete wants.

Purging deletes the rows first and the files after they commit, so a failed file
delete leaves an invisible orphan rather than a page pointing at bytes that are
gone; `mix mirror.blobs.sweep` ([operations.md](operations.md)) is the net for
those. A trashed space is purged as a whole, which is why its page count is on
the screen: the one decision removes the space, its pages, their comments and
every file under them.

## The demo snapshot

With no `CM_CONFLUENCE_SITE` (or `CM_SOURCE=demo`) a realistic snapshot is built
in memory — nested trees, cross-space links, labels, comments, attachments,
archived pages and the common macros — through the same pipeline as a real site.
The [README](../README.md#1-see-it-working) has the commands.

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

Links are stable: pages are keyed by `confluence_id` and version, and the title
part of the URL follows Confluence's own rule — ASCII words joined with `+`, so
"API /v2: changelog? (draft) #2" becomes `API+v2+changelog+draft+2`. A page
whose title has no ASCII words in it (Cyrillic, CJK) gets no title segment and
is served by id alone, exactly as Confluence serves it. Any other segment — an
old slug, a typo, a title that was since renamed — redirects to the canonical
URL rather than failing, and Confluence's `/wiki` prefix is dropped, so a
Confluence link works here after changing nothing but the host. Headings keep
the ids Confluence gave them and carry a `#` link on hover, so a heading anchor
copied here works there and vice versa.

## Search

Readers search at `/search` (plain text plus filters for space, label, type,
creator, ancestor and last-modified date); the same index backs
`GET /api/v1/search`. Confluence's CQL syntax is available on the
Confluence-compatible REST surface — see [api.md](api.md#search-cql-on-postgres).

## Exporting the mirror

Three ZIPs and a page, one shape: files that work from disk — no server, no
network, no build step.

| Where | What | Who |
| --- | --- | --- |
| `/spaces/:key/site.zip` (space overview → Export) | that space as a static site | anyone who may read the space |
| `/admin/export/site.zip` (admin dashboard → Static site) | every space as one static site | administrators only |
| `/spaces/:key/export.zip` | that space as Markdown + attachments | anyone who may read the space |
| `/spaces/:key/pages/:id/export.md` (page rail → Export) | one page as Markdown | anyone who may read the page |
| `/spaces/:key/pages/:id/export.zip` (page rail → Export) | one page as Markdown + the files it links to | anyone who may read the page |

**A download says what it is and when it was made**, in lowercase words joined
by underscores, with the moment in UTC:

```text
dled_site_20261026T101530Z.zip                  the whole site, as a static site
engineering_handbook_site_20261026T101530Z.zip   one space, as a static site
engineering_handbook_markdown_20261026T101530Z.zip  one space, as Markdown
architecture_overview.md                        one page
architecture_overview_markdown_20261026T101530Z.zip  one page, with its files
```

So two copies of the same space sit side by side in a downloads folder instead
of the second replacing the first, and nothing in a name needs quoting on a
command line or in a URL.

**The page ZIP is the one to take if images matter.** A `.md` file names its
pictures but carries none of them, so a viewer paints a broken frame. The ZIP
unpacks into

```text
architecture_overview.md
attachments/architecture.csv
attachments/diagram.svg
```

with the Markdown pointing at `attachments/…`, so the page reads as it does
here. It carries the files the body links to and nothing else; a link to
another page's file stays a Confluence address, because that file is not this
page's to hand out.

The static site contains:

```text
index.html                        every space in the archive
search.html                       search over this copy (works offline)
labels/index.html                 every label, with a count and how many spaces
labels/<label>.html               every page carrying one label
spaces/<KEY>/index.html           description, categories, icon and the page tree
spaces/<KEY>/pages/<id>.html      one page: body, files, child pages, comments
spaces/<KEY>/pages/<id>.md        the same page as Markdown
spaces/<KEY>/icon.<ext>           the space icon, when the mirror has it
attachments/<KEY>/<page>/<file>   the mirrored attachments
assets/site.css                   the site's compiled theme
assets/site.js                    folding the page tree, switching the theme
assets/theme.js                   the pinned theme, applied before the first paint
assets/search.json                the search index, for other tools
assets/search.js                  the matcher search.html runs
```

**Links follow the rule the mirror already applies.** A link to a page the
archive carries becomes a relative file — including a link written as a full
Confluence URL on the site's own address. A link to a page the archive does not
carry (a restricted page in a reader's copy, another space's page in a
one-space archive) goes back to Confluence. A reader's copy carries only what
that reader may open.

**The look is the site's.** `assets/site.css` is the stylesheet this instance
serves — the theme an administrator picked, custom skins included — and every
page is written with the same markup as the reader screens. Nothing on a page
is built by script: the heading permalinks are in the HTML, and the two scripts
an archive carries only fold the page tree away and switch the theme, so a page
with scripts blocked still reads.

**Reading a page is as comfortable as in the mirror.** The page tree folds away
and stays folded (`site.js` remembers the choice in the browser, like the reader
screens do), the theme cycles system → light → dark from the button in the
header, and the prose keeps the reader's measure — a line about eighty
characters wide — however wide the window is. `theme.js` runs in the head, so a
reader who pinned dark never sees a white flash first. Printing hides the tree,
the rail, the header and the footer, drops the heading permalinks, and gives the
column the page's width. All of it is optional: with scripts blocked the page
still reads, follows the system's theme, and shows the tree.

**Comments travel with their page.** A page carries its discussion — roots and
replies, with the same rewriting as the body — and a screenshot pasted into a
reply is exported under the page it hangs off, so the link in the comment
resolves. Label chips lead into `labels/`, which is the way in the page tree
cannot give: everything about one subject, whichever space it lives in.

**Search is part of the folder.** `search.html` carries the index inline, so
it works when the archive is opened from `file://` (where a page may not fetch
its own files). Each document is a page's title, space, labels, date and the
first 400 characters of its text; matching is client-side and ranks titles
above spaces and labels, above the body.

Typing into the field says what is happening: the search waits for a pause in
typing (150 ms) and then scans in slices, showing a spinner and "Searching… n%"
while it works, so a site of a hundred thousand pages neither looks dead nor
freezes the field. A newer query abandons the older scan, so a result can never
land under the wrong word. The percentage is hidden from screen readers; they
hear the settled count ("23 pages match") once.

Every page carries the trail that leads to it — space, then each parent — and
a link to the space's front page, which holds the space's whole page tree
once. That is deliberate: a tree in every page makes the archive quadratic, and
a space of 900 pages would ship its tree 900 times.

The ZIP deflates what deflation helps (HTML, Markdown, JSON) and stores what it
does not (attachments are usually already compressed), and it is written in the
ZIP64 format when a site needs it — more than 65,535 files, or more than 4 GiB —
so the archive stays readable. As a guide: a 935-page space is about 2 MB; a
site of 120,000 mostly-title-only pages is a few hundred MB, and takes minutes
to prepare.

What it does not do: content Confluence renders only in the browser (Jira
issues, page trees, gadgets) already reads as the mirror's "cannot be shown in
the static mirror" note, and syntax highlighting — a reader-screen script —
is not applied to exported code blocks.

## Who may read what

Access is mirrored, not invented. Confluence decides who may read a page, and the
mirror replays that decision:

> This page is about *what an admitted reader may open*. Who gets an account at
> all — the proxy's identity, `CM_USER_POLICY`, `CM_ADMINS`, `CM_ADMIN_GROUPS`,
> and which route accepts which credential — is
> [routes-auth.md](routes-auth.md), next to this guide.

The rules themselves — a space without rows is open, a page restriction narrows
it, a personal space belongs to its owner, an administrator sees everything — are
stated once in
[routes-auth.md](routes-auth.md#authorization-what-an-admitted-reader-may-see).
Two consequences matter to an operator:

* **A space whose permissions the source cannot report stays open.** Confluence
  Cloud exposes space permissions as writes only, so the mirror shows what the
  sync account can read (see [known limitations](design-notes.md#known-limitations)).
* **A personal space is never open**, whatever its (usually empty) permissions
  say: otherwise "no rows means open" would publish one person's drafts.

Readers are matched by every identity their account stands for: its e-mail
address, the identity it signed in with, and any further Confluence identity an
administrator linked to it (`users.identity_account_ids`, see
[Accounts, tokens and identities](#accounts-tokens-and-identities)); group names
are the mirrored groups, plus any group granted on this mirror.

### Permissions: who may read what

`/admin/permissions` is the administrative view of the two tables those rules
read. It answers, per space, who narrows it — groups, people, anonymous readers
— and, behind *Inspect*, which pages carry restrictions of their own and who
each one names.

Every question has an address, so a screen can be linked rather than described:
`/admin/permissions` is the directory (`?q=` filters it),
`/admin/permissions/LOAD101` is one space, and
`/admin/permissions/LOAD101/pages/42` is one page of it. A key nobody has sends
you back to the directory with a sentence; a page that is not in that space
sends you to the space.

Two decisions can be made here, and both are the mirror's own — nothing is
written back to Confluence:

* **Grant** (*Add people or groups*) — let one more reader in. Only a subject
  the mirror knows can be named (a person the content or a permission names, a
  group the sync has read), and only on a space or page that is already
  narrowed: on an open one there is nothing to widen, and the row would read as
  the restriction itself.
* **Remove** — stop an identity the site lists. The site's row is kept and
  marked, so the next sync neither brings the reader back nor loses the
  decision; *Restore* undoes it immediately, without waiting for a run.

Both are one row with a marker (`granted_by_id` / `revoked_by_id`) in
`space_permissions` or `page_restrictions`, so every access rule keeps reading
one table. A space or page whose readers were *all* removed reads **closed**,
not open: "no rows" already means "everybody", and a removal must never turn
into an opening.

The boundaries, in one place:

* a sync replaces only the rows it wrote; grants and removals survive it, even
  when the site keeps naming the same identity;
* when the site opens a space or page again, the overlay rows go with it —
  there is nothing left to widen and nothing left to take away, and neither may
  become the reason a resource is narrowed;
* when a page is trashed — by a sync that no longer sees it, or by an
  administrator — its grants and removals are deleted: they were decisions
  about a page somebody could open. A trashed space loses its own overlay the
  same way, and its pages' with it. The site's rows stay, because the trash
  keeps them for the audit trail and a page that comes back is re-read from the
  source;
* every grant, revocation, removal and restoration is in the audit log as
  `space.access_*` / `page.access_*`, with the identity named.

A removal is a refusal by the mirror, not by Confluence, and the *Removed here*
list says exactly that beside the readers the site still lists.

The reader UI applies the policy to the space directory, the global space menu,
page and blog views, label/recent listings, attachment downloads and exports; a
hidden resource is a `404`, never a `403`, so the mirror does not confirm what
it withholds. The v1 JSON API, the Confluence-compatible API and the `/search`
LiveView answer as the caller does: their results pass through the same
`Authorization` checks, so a reader cannot find in them what the reader-side
directory hides.

## Themes and variants

Two decisions, kept apart:

* the **theme** is the brand — the palette pair behind every screen. One theme
  is active for the whole site, and an administrator chooses it on
  [`/admin/settings`](#the-admin-area).
* the **variant** is each reader's own: `system`, `light` or `dark`, from the
  menu in the header. `system` follows the OS. A variant never changes the
  palette, it chooses which half of it paints — and it is a cookie
  (`mirror_theme`), so the first paint is already right and no JavaScript is
  involved.

Two themes ship:

| theme | what it is |
| --- | --- |
| `default` | the warm light palette and the violet dark one, compiled into `assets/css/app.css` as daisyUI's `light` and `dark` themes |
| `fresh-blue` | a blue-and-slate pair with small radii and flat surfaces, shipped as a skin pack and emitted per request |

`fresh-blue` is the theme the mirror wears out of the box.

### Choosing the theme

**Admin → Settings** lists the themes the site offers; pick one and save. The
choice lives in the `settings` table, so it survives a restart and needs no file
edit; the save is audited (`settings.theme`). Readers keep their variant: someone
who chose `dark` stays on `dark` across a theme change, because every theme
answers to the same three variant names.

`CM_THEME` (or `config :confluence_phx_mirror, theme: "fresh-blue"`) seeds the
same decision for deployments that want it without a manual step:

```elixir
# config/runtime.exs, or CM_THEME=fresh-blue in a release
config :confluence_phx_mirror, :theme, "fresh-blue"
```

The seed applies until an administrator saves a theme. A seeded name the site
does not offer stops the release at boot rather than quietly serving the
default theme.

### A theme declared in config

Site authors add their own theme in config — no CSS edit, no asset rebuild:

```elixir
# config/runtime.exs (or config/dev.exs)
config :confluence_phx_mirror, :skins, [
  %{
    name: "acme",                   # cookie-safe: a-z, 0-9 and dashes
    label: "Acme",                  # shown in the admin's picker
    note: "blue on white",          # one line under the label
    colors: %{                      # the light palette
      base_100: "#ffffff", base_200: "#f2f6ff", base_300: "#d3deef",
      base_content: "#11213d",
      primary: "#0b5fff", primary_content: "#ffffff",
      secondary: "#3d5afe", accent: "#00a3bf"
    },
    dark_colors: %{                 # optional; a theme without one stays light
      base_100: "#0d1117", base_content: "#e6edf5",
      primary: "#4d9bff", primary_content: "#0d1117"
    },
    radius: %{box: "0.75rem", field: "0.375rem"}
  }
]
```

The palette is emitted as `[data-theme="acme"]` rules per request — the light one
as the base rule and the dark one under `[data-scheme="dark"]`, plus a
`prefers-color-scheme` block for readers on `system`. Every daisyUI component
reads its colours from those variables, so buttons, panels and the Confluence
content pick it up immediately. Supported keys are the daisyUI colour names
(`base_*`, `primary`, `secondary`, `accent`, `neutral`, `info`, `success`,
`warning`, `error`, each with `_content`), the three radii, plus `border`,
`depth` and `noise`. Unknown keys and values that are not plain CSS values are
ignored.

### Skin packs: standalone extensions

A theme that should ship as its own module — an internal package, a dependency,
or a file dropped into `lib/` — is a *pack*: any module implementing
`ConfluencePhxMirrorWeb.Skins.Pack`, listed under `:skin_packs`.

```elixir
config :confluence_phx_mirror, :skin_packs, [MyCompany.Skins]

defmodule MyCompany.Skins do
  @behaviour ConfluencePhxMirrorWeb.Skins.Pack

  @impl true
  def skins do
    [%{name: "my-company", label: "My Company", colors: %{primary: "#0b5fff"}}]
  end
end
```

Pack themes take the same keys and are validated the same way; a pack cannot
shadow a built-in theme, and a config theme wins when both declare the same
name. `ConfluencePhxMirrorWeb.Skins.FreshBlue` is the reference pack — start
there when writing your own.

For anything a palette cannot express — fonts, spacing, component tweaks — edit
`assets/css/author.css`, which is loaded after the main stylesheet. Scope rules
to `[data-theme="acme"]` so they only affect that theme. A brand-new *built-in*
theme (shipped in the compiled CSS) is a
`@plugin "daisyui/packages/bundle/daisyui-theme"` block in `assets/css/app.css`,
next to `light` and `dark`.

`config/dev.exs` leaves both defaults alone, so development shows what a reader
sees — Fresh blue, with the variant menu in the header.

## The site's own configuration

Confluence's **General configuration** mixes two kinds of decision, and only one
of them can travel. A sync reads what Confluence Cloud still answers over REST:

```
GET /wiki/rest/api/settings/systemInfo
→ siteTitle, defaultLocale, defaultTimeZone
```

That is the whole synced list, and it happens once per run, before any content —
a snapshot, a single page, a webhook delivery. The language becomes the
document's `<html lang>` on every page, on error pages and in the static export;
`en_GB` on the site is `en-GB` in the document. A change is one audit entry
(`site.settings_read`); an answer that repeats itself is none. If the endpoint
cannot be reached the run logs a warning and carries on — a title is not worth
failing a sync over, and a site that never answered is not a site that switched
its title off.

Everything else on that screen is **not** exposed by Confluence Cloud over REST
(the admin UI reads it over GraphQL with a browser session), so it is the
mirror's own setting and you set it here:

| General configuration | what the mirror does |
| --- | --- |
| Site title | **synced** — kept for the admin screens and the audit trail; the shell's own name stays `CM_MIRROR_NAME` / the `sites` row |
| Default language | **synced** — the document's `<html lang>` |
| Time zone | **synced** — used by the export and the mail the mirror sends; dates inside a page arrive already formatted by Confluence |
| Site landing page | **mirror setting** — `/` is the mirror's own home or its space directory: **Admin → Settings → Site** (`CM_LANDING_PAGE`) |
| Default page width | mirror setting — the page view is the mirror's layout, not the site's |
| Date, time and number formats | mirror setting — a body is stored as Confluence rendered it |
| Maximum attachment size, attachments per upload | mirror setting — `Storage` caps what this mirror accepts from a reader |
| Presence avatars, likes | not mirrored — read-only mirror |
| Block templates, contact form, e-mail and push switches, global permissions | not mirrored — they configure authoring and mail on the site, and neither happens here |

The synced three are re-read by any run, so asking the site again is one click:
*Re-read everything* on `/admin/sync`, or a single page's resync. Neither is
needed for a rename to show up eventually — the scheduled pull reads them too.

## Notifications

### The mail server

Nothing is mailed until there is a server to mail it through. With no
`SMTP_RELAY` and nothing stored, the deployment keeps Swoosh's *Local* adapter:
mail is written to a file and never sent — which is what a fresh deployment does,
and why "watchers get no e-mail" is usually this and not a bug in the watch.

**Admin → Settings → Mail server** takes the relay, port, username, password, and
whether TLS and authentication are used. A stored value wins over the
deployment's `SMTP_*` and takes effect on the next message — `Mailer.configure/0`
rebuilds the adapter at boot and after every save. The password is write-only: the
field says whether one is stored, and leaving it blank keeps the one in force.

Readers can watch a page or a whole space from the page rail.

* `instant` – one e-mail per changed page (Oban retries, outbox row with
  delivery status);
* `daily` – rolled up by `Notifications.DigestWorker` at
  `MIRROR_DIGEST_HOUR_UTC`.

Development uses smtp4dev: SMTP on `localhost:2525`, web UI on
<http://localhost:3001>. `config/test.exs` uses Swoosh's test adapter.
Set `MIRROR_MAIL_FROM` and the Swoosh mailer settings for production.

## Signing in

* Development/test: admin is assumed (`MIRROR_AUTO_ADMIN`), so no sign-in is
  needed there.
* Production: passwordless magic-link sign-in (single-use, `CM_LOGIN_TOKEN_MINUTES`
  minutes, self sign-up controlled by `MIRROR_SELF_SIGNUP`).
* Administrators are accounts with the `admin` role, members of an admin group
  (`CM_ADMIN_GROUPS`, default `confluence-admins`) or seeded e-mails
  (`CM_ADMINS`). Seeded addresses can always request a sign-in link, even with
  self sign-up closed, so a fresh deployment has a way in.
* API tokens: the reader creates their own under `/profile` (*API tokens*), shown
  once and stored as a digest. Nobody can create one for somebody else; an
  administrator can revoke a leaked one from *Users & tokens*, which only takes
  access away. The client side is [api.md](api.md#authentication).
* Behind an OAuth2/SSO proxy: `CM_PROXY_AUTH=true` trusts the identity header
  the proxy sets, so there is no sign-up step; roles and groups stay local.
  Enable it only when the app cannot be reached except through the proxy. Who is
  then admitted — administrators, and identities the sync has read about, authors
  included — is
  [routes-auth.md](routes-auth.md#admission-may-this-identity-have-an-account);
  everyone else gets a `403` page and no account is created.

## Switched-off accounts

*Users & tokens* lists every account with a filter box (e-mail or name) and the
flags that keep people out. They are independent, because different people
decide them — but they are not equally final:

| Flag | Set by | Shown as | Can it be lifted here? |
| --- | --- | --- | --- |
| `disabled_at` | an administrator, on that screen | *disabled here* | yes, with *Switch on here* |
| `site_disabled_at` | the sync, when Confluence reports the account as not active | *disabled on the site* | only on the site |
| `site_deleted_at` | the sync, when Confluence no longer has the account (404, or closed there) | *deleted on the site* | no — the account would have to exist again |
| `banned_at` | an administrator, on that screen | *banned* | yes, with *Lift ban* |

An account is refused while **any** of the first three applies — the effective
state is their OR — but they stay apart so an operator can tell "we did this"
from "the site did this". Switching an account off here leaves Confluence alone;
the site's flags rewrite themselves on the next sync that sees the account again.

*Switch on here* is deliberately not called "enable": it lifts the mirror's own
flag and nothing else. If Confluence switched the person off, they stay out, and
the account row says so.

### Asking the site again, without waiting for a pull

The site's flags are written by a run that sees the site's people, which every
run does *except* a single page: group memberships are re-read, and each identity
the mirror knows is asked for its own status. On a scheduled mirror that means
the next pull — hourly by default.

When that is too long (somebody was removed from an admin group, or switched off
this morning), both screens that show people have the same button:

| Screen | Button | What it reads |
| --- | --- | --- |
| *Users & tokens* → header | *Re-read people* | every group the content names, and each account's status. **No page is listed and no body is read** |
| *Confluence identities* | *Sync with Confluence* | the same run |

It queues a job rather than running in the request, so the answer arrives in the
background: the sync log names it (`the users screen, by …`), and the users list
redraws itself as the run writes what it found (each change is an audit event).
A removed member of an `CM_ADMIN_GROUPS` group stops being an administrator at
that point; a removal from the site never lifts a role granted on this screen or
an address listed in `CM_ADMINS` — those are the mirror's own decisions.

### Letting switched-off readers back in

A mirror usually follows the site on access, which is the safe default. Some
mirrors are meant to outlive an account being stood down — a leaver whose
knowledge should stay readable. Set

```
MIRROR_ALLOW_SITE_DISABLED_READERS=true
```

and readers Confluence reports as *inactive* may read the mirror again. The
site's *deleted* state is never relaxed, and neither is a ban: those two are
about a person being gone, not switched off. `/admin/settings` shows which
answer this deployment gives.

### Banning, and why a ban blocks deletion

A ban is not a switch-off. Nothing lifts it but an administrator: a sync that
finds the account active leaves the ban alone, and a banned account **cannot be
deleted**. That second rule is the point — deleting the row would let the next
sign-in provision a fresh, unrelated account, which is exactly what a ban is
supposed to prevent. Lift the ban first if you really want the account gone.

An account that is merely switched off (here or on the site) can be deleted:
*Delete* removes the row with its API tokens, login tokens and subscriptions. It
does not touch Confluence. The last administrator cannot be deleted, for the
same reason they cannot be demoted.

Switching off takes effect immediately: an existing session is ignored, API
tokens answer `403 account_disabled`, magic links can be neither requested nor
consumed, and the proxy refuses the identity. Nothing is deleted, so switching
an account back on here restores access as it was, minus whatever the site
decided in the meantime. A seeded or bootstrap administrator cannot be switched
off here — the same reason they cannot be demoted: it would remove the only way
back in.

The site's flags come from asking Confluence about the Atlassian accounts the
mirror knows (page authors, group members, readers who signed in with an account
id). There is no user directory to walk — Cloud does not expose one — so an
account nobody here has ever seen is simply not checked.

Every change is audited: `user.disabled` / `user.enabled` for the flag set here,
`user.banned` / `user.unbanned` for a ban, `user.deleted` when an account is
removed, and `user.site_disabled` / `user.site_enabled` / `user.site_deleted`
when the sync sees the site's state change. The sync writes transitions only, so
an hourly run does not fill the log with "still active".

### Never lock yourself out

The mirror always keeps one administrator. Seeded (`CM_ADMINS`) and bootstrap
accounts cannot be demoted, switched off, banned **or deleted** — the rule is
about the row, not about how many administrators there are. Neither can whoever
is left: if an account is the last one that can administer the mirror, the role
select, the switch, the ban and the delete are all locked, and the page says
which rule applies. Stepping down works again as soon as somebody else can take
over — another `admin` account, a member of an `CM_ADMIN_GROUPS` group, or a
seeded address that has not signed in yet.

Deleting a seeded administrator would not stick anyway: the next boot seeds that
address again, and the row would come back with none of its history. So it is
refused rather than undone.

## Accounts, tokens and identities

Every reader has an account page at `/profile`, reachable from the avatar menu
in the top bar. It has two tabs:

* **Profile** — the e-mail and role the mirror knows, how the account is an
  administrator (role, admin group or seeded), when it last signed in, and the
  groups it is in, split into what the last sync read and what an administrator
  granted here.
* **API tokens** — the reader's own tokens. One is created here, shown once, and
  revocable here. A token acts as its owner, so **no administrator can create
  one for somebody else**; what *Users & tokens* keeps is a list of the tokens
  an account has and the *Revoke* action, which only takes access away.

### Adding a person before they arrive

An account can exist ahead of its first sign-in. **Add a person by e-mail** at
the top of *Users & tokens* takes an address and a role, writes the account —
audited as `user.created` — and nothing else: no sign-in, no Confluence
credentials, no invitation. Their first sign-in with that address claims it,
because `Accounts.create_user/2` writes no `provisioned_at` and no sync ever
removes an account the mirror made itself.

That is what makes a decision *ahead of* the first visit possible: create the
account, link the Confluence identity on *Identities*, put it in a group, watch
a space — before the person has ever opened the mirror. The same door exists for
scripts: `POST /api/v1/users` (see [the API guide](api.md#json-api)).

### Linking a Confluence identity to an account

One person often holds two Atlassian accounts — a personal one and a guest or
contractor one — and Confluence's content and permissions may name either.
*Admin* → *Identities* is where an identity is **linked** to a mirror account,
and unlinked again. It is the only place that decides who a person is; the
account rows on *Users & tokens* only say what an account already holds.

A site can name a hundred thousand people, so neither side of the screen lists
them: both are searched, and a link is a click. The filter is a URL parameter
(`/admin/identities?q=…`), so a colleague can send a link to the identity they
mean.

**Sync with Confluence** on that screen queues a *people* run: it asks the site
which groups each identity the mirror knows is in, and who the members of every
group the content names are — and it lists no page at all, so it costs a
fraction of a sync. That is the button for "somebody joined a group an hour ago";
the hourly sync answers the same question but also walks every space. The run
appears in *Jobs* and in the sync history like any other, with `people` as its
mode.

* From an identity: filter by the name Confluence shows or by the account id,
  then **Link to an account…** opens a picker that searches the mirror's
  accounts. Clicking one makes the link.
* From an account: the *Add an identity to an account* panel searches the
  account first, then offers the people no account holds yet. An identity
  another account already holds is listed with whose it is and offers no
  button, because moving one is a decision about two accounts.

What the identity carries becomes the account's: its group memberships, the
spaces and pages it is named in, and the content it authored. The rule is the
union — `User.identity_keys/1` answers with every linked identity, so what a
reader may open is everything any of their identities may open, whether they
arrived by a page or by an API token.

Two things are refused: an identity the mirror has read nothing about (a typo
would otherwise be a grant that silently does nothing — run a sync first), and
an identity another account already holds. Linking and unlinking are an
administrator's decision and are enforced in `Accounts.link_identity/3`, not in
the screen, so an API or MCP caller passing a member's account gets
`{:error, :not_authorized}`. Both appear in the audit log as
`user.identity_linked` / `user.identity_unlinked`.

Scripts can do the same thing with an administrator's token —
`GET /api/v1/identities`, `POST /api/v1/identities/:account_id/link` and
`DELETE /api/v1/identities/:account_id/link`; see [the API guide](api.md#json-api).

### Groups granted here

`/admin/users` can grant a group on top of what the sync says — an incident
rotation, a group Confluence does not have. The picker offers the group names
the last sync actually read, so a grant is a name that exists; a free field is
there for a group no sync has seen yet. A grant here is never taken away by a
sync, and it never removes a group Confluence reports.

## People the site names

Confluence Cloud does not expose a user directory, and it no longer answers
"who is in this group" (`GET /group/{name}/member` is gone). What it does answer
is "which groups is this account in", so the sync learns membership one person
at a time, for every identity the content names — each page author and comment
author. Those people are listed under *Users & tokens* with the groups the last
sync read for them, whether or not they ever signed in here.

The membership rows are the same ones the access rules read, so an admin group
(`CM_ADMIN_GROUPS`) grants administration as soon as one of its members appears
as an author, and a restriction on a group applies to the readers in it. A sweep
is capped at 200 identities per run to keep a snapshot bounded.

## Webhooks

A webhook is how the mirror hears about a change before the next scheduled pull:
Confluence `POST`s to `/webhooks/confluence` and the mirror syncs the one page —
or the one space — that changed.

### Setting it up

1. Give the mirror a secret: `CM_WEBHOOK_SECRET`. Restart it; `/admin/webhooks`
   stops warning that webhooks are not configured.
2. In Confluence, add a webhook (Administration → *Webhooks*) pointing at
   `https://<mirror-host>/webhooks/confluence`, with that same secret. Cloud
   signs the **raw** request body with HMAC-SHA256; the mirror accepts
   `X-Hub-Signature-256`, the legacy `X-Hub-Signature` and Atlassian's
   `X-Atlassian-Webhook-Signature` (`sha256=` prefix optional).
3. Subscribe to the events you care about — the mirror understands
   `page_created`, `page_updated`, `page_removed`, `page_trashed`,
   `page_deleted`, `page_restored`, `page_moved`, `blogpost_created`,
   `blogpost_updated`, `blogpost_removed`, `attachment_created`,
   `attachment_updated`, `attachment_deleted`, `attachment_trashed`,
   `comment_created`, `comment_updated`, `comment_removed`, `comment_replied`,
   `space_created`, `space_updated`. Anything else is stored and marked
   `ignored`, never acted on.
4. Watch `/admin/webhooks` (refreshes every 5 s): the last 50 deliveries with the
   event, whether the signature verified, and what became of it.

The signature covers the exact bytes Confluence sent, so do not put a proxy in
front of the endpoint that rewrites or re-encodes the body.

### Three ways in — and what happens to a fourth

| Sender | Presents | Configured by |
| --- | --- | --- |
| Confluence Cloud | `X-Hub-Signature-256` HMAC over the raw body | `CM_WEBHOOK_SECRET` |
| A sender that cannot compute an HMAC | a fixed token in `X-Webhook-Token`, `Authorization: Bearer` or `?token=` | `CM_WEBHOOK_TOKENS="confluence=s3cret"` |
| Anything you automate | a service token with the `webhook` scope (*Users & tokens*) | the admin UI, revocable per token |

A delivery with **neither** is unauthenticated. That is accepted by default — a
mirror pointed at a Confluence site should work before anybody changes a
setting — and `/admin/webhooks` shows a red banner for as long as it is accepted:
whoever can reach `/webhooks/confluence` can make the mirror sync a page or mark
one deleted. Every such delivery is still recorded, with `signature_valid =
false`.

The switch is on that page and takes effect on the next delivery, with no
restart: *Require signatures* closes the intake; *Allow unsigned* opens it again.
The deployment sets the default — `CM_WEBHOOK_REQUIRE_SIGNATURE=true` with
`CM_WEBHOOK_SECRET` closes it from boot, and `false` (the shipped default) leaves
it open. An administrator's choice overrides the variable until they hand it back
with *Use the deployment setting*; either way the decision is audited.

A signature that *is* presented always has to verify: a delivery that pretends to
be authenticated and is not is refused (`401`), whatever the switch says. A
token, by contrast, is enough on its own. If no `CM_WEBHOOK_SECRET` is configured
and signatures are required, the answer is `503
webhook_secret_not_configured` — so "not set up" stays distinguishable from
"wrong secret".

### Turning the intake off

A mirror behind a sign-in proxy, whose sync is scheduled anyway, has no reason to
be reachable by the site. *Switch off* on `/admin/webhooks` — or
`CM_WEBHOOK_ENABLED=false` in the deployment — refuses every delivery and stores
nothing, not even the attempt: a switched-off intake is not a delivery log.

The refusal does not announce itself. It answers with the endpoint's own 404,
byte for byte the same page any unrouted path returns, because a `410 Gone` or an
`error: webhooks_disabled` body would tell an anonymous caller that a webhook
endpoint lives here and what it is for. The plug therefore stands before
`:accepts` in the pipeline: picking a format first would render a JSON 404 where
an unknown path renders HTML, and that difference is itself an answer.

Changes still arrive with the scheduled pull, so this costs freshness, not
correctness. It is a different decision from requiring signatures, which says
*who* may post rather than *whether* anyone may; the page shows both, and each
can be handed back to the deployment separately.

### What it will act on

The intake reads a fixed shape and ignores everything else, because it may be
answering an anonymous caller:

| Field | Accepted | Otherwise |
| --- | --- | --- |
| `event` | a name in the list above | stored, `ignored` |
| page id (page, blogpost, attachment container, comment container) | a whole positive number | stored, `ignored` |
| space key | `[A-Za-z0-9][A-Za-z0-9_-]*`, at most 255 characters | stored, `ignored` |
| body | at most 1 MiB | `413 payload_too_large`, nothing stored |

"Ignored" deliveries keep their payload for inspection and spawn no work.

Tokens are route-scoped: they are accepted on the webhook route and nowhere
else — not by the API, not by the reader UI.

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

### Metering

The intake is metered even when reader limits are switched off, because a
delivery is stored — and audited — *before* its signature is checked: those rows
are written by whoever can reach the port. The cap is per client address
(`conn.remote_ip`, never `X-Forwarded-For`), `CM_WEBHOOK_RATE_LIMIT_PER_MINUTE`
(default 60), answered with `429` and `Retry-After` before anything is stored.
Behind a reverse proxy every sender shares that one bucket — correct for a
single Confluence sender, worth knowing if several sites post here. An
administrator can move the cap on `/admin/webhooks` without a restart; the
variable stays the default.

### What a delivery triggers

| Event | What happens |
| --- | --- |
| page, blog post, attachment or comment created/updated/restored/moved/replied | one **page** sync of the affected page |
| page or blog post removed/trashed/deleted | the page is marked deleted immediately, no worker involved |
| `space_created`, `space_updated` | one **space** sync |
| anything else, or a payload naming no page | stored, marked `ignored`, audited |

Jobs for the same page within 60 s are coalesced (Oban uniqueness on
`confluence_id`), so a burst of edits costs one sync rather than one per event.

A page sync re-fetches that page and nothing else, plus what hangs off it: the
page body, its attachments, its comments and its own read restrictions — then
the space's permissions and the site's group membership, because those decide
what the new body may show. It then re-expands the macros on *every* page
carrying a marker, since a label or a property on this page changes what those
listings say (see [design notes](design-notes.md#dynamic-content-macros-the-browser-would-normally-run)).
That is the mirror's answer to "what depends on this page": it re-derives the
listings rather than tracking a dependency graph.

A delivery is never replayed by the mirror — the payload is stored, so if a
job failed you re-POST it (or run `mix confluence.sync --mode page --page 1002`).
The page sync itself retries five times before the run reports the failure on
`/admin`.

## Troubleshooting

| Symptom | Meaning |
| --- | --- |
| `mix confluence.probe` → `401` | the e-mail/token pair is wrong |
| `mix confluence.probe` → `403 caller cannot access Confluence` | that account has no Confluence product access on the site (common with Jira-only accounts) |
| Webhook answers `503` | signatures are required but no `CM_WEBHOOK_SECRET` is configured; the delivery is recorded as rejected |
| Webhook answers `401` | a signature was presented and did not verify, or a token is configured and the wrong one was sent |
| Webhook answers `413` | the body is over 1 MiB — Confluence sends one page, not a bundle |
| Webhook answers `429` | the intake cap was hit — 60 deliveries a minute from one address by default; raise it on `/admin/webhooks` |
| A sync ends `partial` | at least one page failed — read the run's errors on `/admin`; nothing was silently dropped |
| A reader gets `404` for a page that exists in Confluence | a page restriction hides it from that reader; hidden resources are never confirmed with a `403` |

## Where next

The other guides — configuration, operations, API, design notes, developer notes
— are listed in the [README](../README.md#documentation).
