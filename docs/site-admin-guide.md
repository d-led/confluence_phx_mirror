# Site administration

This guide is for the mirror's site administrator: you run the mirror as a
product. You point it at a Confluence site (or use the demo snapshot), keep the
content current, decide who may read what, manage accounts and access, choose
the theme, and wire up webhooks.

Deploying, upgrading and scaling the app itself is a separate job — see
[operations.md](operations.md). Every setting is listed in
[configuration.md](configuration.md), and API consumers start at
[api.md](api.md).

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
  `429`/`5xx` with backoff, and never follows redirects;
* only ever talks to the configured host (`SafeURL`), with response size caps;
* details changed pages `CM_SYNC_CONCURRENCY` at a time, and supports
  `CM_SYNC_INTERVAL_SECONDS` for scheduled pulls (incremental by default).

## Pulling content

```bash
mix confluence.sync                              # incremental pull
mix confluence.sync --mode snapshot              # full re-read of every page
mix confluence.sync --mode space --space ENG     # one space
mix confluence.webhook --page 1002 --event page_updated
```

A sync is recorded as a run (`running` → `succeeded` / `partial` / `failed`)
with counters and errors. Failures are **per page**: one broken attachment or
comment does not abort the run. Pages missing from a snapshot are marked deleted
(rows are kept for audit); attachments removed in Confluence are deleted from
Postgres and the blob store. A source that suddenly lists no pages for a space
never marks that space's content deleted — the run is flagged `partial` instead.

The mirror is **read-only**. Readers cannot edit anything; content only changes
when a sync pulls a newer snapshot.

## Keeping the mirror current

* `CM_SYNC_INTERVAL_SECONDS` (default `3600`) schedules snapshot pulls; `0`
  disables them.
* Webhooks react to single changes within seconds — see [Webhooks](#webhooks).

## The admin area

Everything you need to operate the mirror as a product lives under `/admin`,
split by what each page is for. Every page carries the same tab strip, so you
can move between them without going back to a hub:

* `/admin` (**live**, refreshes every 5 s) – the overview: freshness, sync runs
  (counters, errors, `running` → `succeeded` / `partial` / `failed`), recent
  activity and recently updated pages, plus the manual sync actions and
  "Re-read everything" for a full pull.
* `/admin/sync-log` (**live**) – the live log: every page, file and call to
  Confluence a sync touches — status, size, latency, retries and the waits the
  client-side rate limiter imposed — plus a summary line when the run ends
  (calls, bytes, retries, throttled time, failures and the answers the site
  gave), held in memory while the run is fresh, with level and text filters.
* `/admin/webhooks` (**live**, refreshes every 5 s) – what Confluence sent and
  whether its signature checked out, including rejected deliveries, plus
  whether a secret and fixed tokens are configured.
* `/admin/audit` (**live**) – the audit log: decisions and changes (accounts,
  tokens, subscriptions, webhooks) and one entry per sync with its counters and
  what triggered it.
* `/admin/users` (**live**) – accounts, roles, mirrored groups and API tokens.
* `/admin/settings` (**live**) – the setup screen. The theme every reader wears
  is a form here: pick one, save, and the whole site repaints. Below it the page
  lists what the mirror booted with — source and sync pacing, identity and
  administrators, webhook and mail delivery, rate limits and the blob root —
  each row naming the environment variable that changes it, secrets shown as
  *configured* never printed ([themes and variants](#themes-and-variants)).
* `/health` – database check, content counters and last sync; no auth, so it
  can back a probe ([operations.md](operations.md)).

Scheduled and manual syncs are **incremental**: the mirror asks Confluence only
for content that changed, and a page whose version is unchanged is not
re-rendered or asked for its attachments and comments. The run's stats say how
much that saved (`unchanged` pages, `attachments_downloaded`).

Two tables back the logs and are worth knowing when you query them directly:

* `audit_events` – append-only: `sync.started/finished/failed`, `user.*`,
  `api_token.*`, `subscription.*`, `webhook.*`, `pages.deleted`.
* `sync_runs.stats` – pages seen and changed, attachments downloaded, comments,
  links, notifications, deletions and per-page errors.

A run that ends `partial` is not a failure: something was skipped and the run's
errors say what. A run that ends `failed` means the source itself was
unreachable or rejected the credentials.

## The demo snapshot

With no `CM_CONFLUENCE_SITE` (or `CM_SOURCE=demo`) a realistic snapshot is built
in memory — nested trees, cross-space links, labels, comments, attachments,
archived pages and the common macros — through the same pipeline as a real site.
The [README](../README.md#demo-snapshot) has the commands.

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

Links are stable: pages are keyed by `confluence_id` and version, slugs are
cosmetic and redirect to the canonical URL.

## Search

Readers search at `/search` (plain text plus filters for space, label, type,
creator, ancestor and last-modified date); the same index backs
`GET /api/v1/search`. Confluence's CQL syntax is available on the
Confluence-compatible REST surface — see [api.md](api.md#search-cql-on-postgres).

## Who may read what

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
`users.confluence_account_id`); group names are the mirrored groups.

The reader UI applies the policy to the space directory, the global space menu,
page and blog views, label/recent listings, attachment downloads and exports; a
hidden resource is a `404`, never a `403`, so the mirror does not confirm what
it withholds. The v1 JSON API and the `/search` LiveView still answer from the
unfiltered index — see [Known limitations](design-notes.md#known-limitations).

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

Both end up as attributes on `<html>`: `data-theme` names the theme and
`data-scheme` forces a palette for a theme that is not compiled in.

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

## Notifications

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
* API tokens: admin → *Users & tokens*; shown once, stored as SHA-256 hashes.
  See [api.md](api.md) for how clients present them.
* Behind an OAuth2/SSO proxy: `CM_PROXY_AUTH=true` trusts the identity header
  the proxy sets (`CM_PROXY_AUTH_HEADER`, default `x-forwarded-email`;
  `CM_PROXY_AUTH_NAME_HEADER`, default `x-forwarded-user`) and provisions a
  reader account on first sight, so there is no sign-up step. Roles and groups
  stay local. Enable it only when the app cannot be reached except through the
  proxy.

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

### Three ways in, and no fourth

| Sender | Presents | Configured by |
| --- | --- | --- |
| Confluence Cloud | `X-Hub-Signature-256` HMAC over the raw body | `CM_WEBHOOK_SECRET` |
| A sender that cannot compute an HMAC | a fixed token in `X-Webhook-Token`, `Authorization: Bearer` or `?token=` | `CM_WEBHOOK_TOKENS="confluence=s3cret"` |
| Anything you automate | a service token with the `webhook` scope (*Users & tokens*) | the admin UI, revocable per token |

There is **no** mode that accepts an unsigned delivery: a request presenting
neither a valid signature nor a token is answered `401 invalid_signature` and
recorded as rejected. When no `CM_WEBHOOK_SECRET` is set at all the answer is
`503 webhook_secret_not_configured` instead, so "not set up" stays
distinguishable from "wrong secret". `CM_WEBHOOK_REQUIRE_SIGNATURE=false` only
turns that `503` into a `401` for callers without a token; it does not admit
anyone.

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
single Confluence sender, worth knowing if several sites post here.

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
| Webhook answers `503` | no `CM_WEBHOOK_SECRET` is configured; the delivery is recorded as rejected |
| Webhook answers `401` | the signature did not verify, or no token was presented; the delivery is stored with `signature_valid = false` |
| Webhook answers `429` | the intake cap was hit — 60 deliveries a minute from one address by default; see `/admin/settings` |
| A sync ends `partial` | at least one page failed — read the run's errors on `/admin`; nothing was silently dropped |
| A reader gets `404` for a page that exists in Confluence | a page restriction hides it from that reader; hidden resources are never confirmed with a `403` |

## Where next

The other guides — configuration, operations, API, design notes, developer notes
— are listed in the [README](../README.md#documentation).
