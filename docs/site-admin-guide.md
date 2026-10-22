# Site administration

This guide is for the mirror's site administrator: you run the mirror as a
product. You point it at a Confluence site (or use the demo snapshot), keep the
content current, decide who may read what, manage accounts and access, choose
skins and wire up webhooks.

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
* supports `CM_SYNC_INTERVAL_SECONDS` for scheduled snapshot pulls.

## Pulling content

```bash
mix confluence.sync                              # full snapshot
mix confluence.sync --mode incremental           # since the last run
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

## The admin dashboard

Everything you need to operate the mirror as a product lives under `/admin`:

* `/admin` – freshness, sync runs (counters, errors, `running` → `succeeded` /
  `partial` / `failed`), the audit log, webhook deliveries (valid and
  rejected) and manual syncs.
* `/admin/users` – accounts, roles, mirrored groups and API tokens.
* `/health` – database check, content counters and last sync; no auth, so it
  can back a probe ([operations.md](operations.md)).

Two tables back the audit log and are worth knowing when you query them
directly:

* `audit_events` – append-only: `sync.started/finished/failed`, `page.*`,
  `attachment.*`, `user.*`, `api_token.*`, `subscription.*`, `webhook.*`.
* `sync_runs.stats` – pages, attachments, comments, links, notifications,
  deletions and per-page errors.

A run that ends `partial` is not a failure: something was skipped and the run's
errors say what. A run that ends `failed` means the source itself was
unreachable or rejected the credentials.

## The demo snapshot

With no `CM_CONFLUENCE_SITE` (or `CM_SOURCE=demo`) `priv` ships no Confluence
content; instead `ConfluencePhxMirror.Confluence.DemoContent` builds a realistic
snapshot in memory (13 pages/blog posts, nested trees, cross-space links, labels,
comments, attachments, archived pages and the common macros). Everything goes
through the same pipeline as a real site.

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
Confluence-compatible REST surface — see [api.md](api.md#search-cql).

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

## Skins

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
delivery. `CM_WEBHOOK_REQUIRE_SIGNATURE` (default `true`) rejects unsigned
deliveries.

## Troubleshooting

| Symptom | Meaning |
| --- | --- |
| `mix confluence.probe` → `401` | the e-mail/token pair is wrong |
| `mix confluence.probe` → `403 caller cannot access Confluence` | that account has no Confluence product access on the site (common with Jira-only accounts) |
| Webhook answers `503` | no `CM_WEBHOOK_SECRET` is configured; the delivery is recorded as rejected |
| A sync ends `partial` | at least one page failed — read the run's errors on `/admin`; nothing was silently dropped |
| A reader gets `404` for a page that exists in Confluence | a page restriction hides it from that reader; hidden resources are never confirmed with a `403` |

## Where next

* [configuration.md](configuration.md) — every environment variable.
* [operations.md](operations.md) — build, deploy, migrate, monitor, back up.
* [api.md](api.md) — JSON API, Confluence-compatible REST, CQL.
* [design-notes.md](design-notes.md) — why the mirror is built this way, and
  what it does not do.
* [developers.md](developers.md) — working on the code.
