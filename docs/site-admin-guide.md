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
comment does not abort the run. Pages and blog posts missing from a snapshot are
**trashed** (marked deleted, rows kept); attachments removed in Confluence are
deleted from Postgres and the blob store. A space missing from a whole-site
snapshot is trashed the same way, with its pages and their comments — and
anything that reappears upstream is live again on the next sync. A source that
suddenly lists no spaces, or no pages for a space, never trashes anything: the
run is flagged `partial` instead.

**Personal spaces are skipped** unless `CM_SYNC_PERSONAL_SPACES=true`. Everyone
on a Confluence site has one (`~accountid`), it holds their drafts, and it is
rarely the site an operator means to publish. The rule holds for every kind of
run — a whole-site snapshot, an incremental pull that happens to find a new page
in someone's private space, a webhook — so the space cannot arrive through the
back door; the run's counters say how many pages it left out
(`skipped_personal`). An incremental run asks the site for its space list to
tell; if that call fails, the run fails rather than guessing. Syncing one space
by key is still a request rather than a discovery: that one is honoured.

A run also settles **who** before **what**: the people it already knows get their
groups read first, then the content, then the groups the content's restrictions
refer to. Confluence never lists its users, so a person the content names for the
first time is picked up at the end of the same run.

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
* `/admin/trash` (**live**) – content a sync no longer finds in Confluence:
  trashed spaces with their page counts, and trashed pages and blog posts, each
  with a purge button. "Empty the trash" asks for a second click. Purging is the
  only thing that deletes content, and it takes the comments and attachment
  files with it.
* `/admin/users` (**live**) – accounts, roles, mirrored groups and the tokens an
  account has, plus the people Confluence's content names, the groups the sync
  read for each of them, and the account each identity is linked to. Tokens are
  *not* minted here: they belong to their owner and are created on
  [the reader's own account page](#accounts-tokens-and-identities). An
  administrator can still revoke one — revoking only takes access away.
* `/admin/settings` (**live**) – the setup screen, in two halves. The top is
  what you can change while the mirror runs: the theme every reader wears, the
  per-reader request limits, and whether notification mail goes out (with the
  UTC hour for the digest). A field you leave empty means "no decision" — the
  value this deployment was configured with applies again, and the placeholder
  shows it. A save is one transaction: either every field of the form and its
  audit entry were stored, or nothing was. The bottom half is what the mirror
  booted with — source and sync pacing, identity and administrators, webhook and
  mail delivery, storage and the proxy — each row naming the environment
  variable that changes it, secrets shown as *configured* never printed. Those
  are read at boot: change the variable and restart
  ([themes and variants](#themes-and-variants)).
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

## Who may read what

Access is mirrored, not invented. Confluence decides who may read a page; the
mirror replays that decision:

> This page is about *what an admitted reader may open*. Who gets an account at
> all — the proxy's identity, `CM_USER_POLICY`, `CM_ADMINS`, `CM_ADMIN_GROUPS`,
> and which route accepts which credential — is
> [routes-auth.md](routes-auth.md), next to this guide.

* **Page restrictions** are read per page
  (`GET /content/{id}/restriction/byOperation/read`) and stored in
  `page_restrictions`. A restricted page is readable only by the listed users
  and groups.
* **Space permissions** are stored in `space_permissions`. Confluence Cloud
  exposes them as *writes only* (`POST`/`DELETE /space/{key}/permission`), so a
  source that cannot read them says `{:error, :not_supported}` and the space
  stays open — the mirror already shows what the sync account can read.
* **A space without rows is open.** Restrictions narrow; they never widen.
* **A personal space belongs to one person.** Confluence keys it by its owner's
  account id (`~5F057CBE0B38B10022628D68`), and only that account may read it —
  whatever its permissions say, because a personal space usually has none and
  "no rows means open" would publish one person's drafts. Nothing about the rule
  is optional: not the space in the switcher, not its pages in search, not its
  pages in an export or a macro listing. Mirror administrators see everything,
  personal spaces included.
* Mirror administrators always see everything.

Readers are matched on e-mail or Confluence account id (`users.groups`,
`users.confluence_account_id`); group names are the mirrored groups.

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
* API tokens: the reader creates their own under `/profile` (*API tokens*);
  shown once, stored as an Argon2id digest (never the token). Raising the
  hashing policy does not invalidate issued tokens — each one is rewritten the
  next time it is used. Nobody else can create one for them: an administrator
  can revoke a leaked token from *Users & tokens*, which only removes access.
  See [api.md](api.md#authentication) for the client side.
* Behind an OAuth2/SSO proxy: `CM_PROXY_AUTH=true` trusts the identity header
  the proxy sets (`CM_PROXY_AUTH_HEADER`, default `x-forwarded-email`;
  `CM_PROXY_AUTH_NAME_HEADER`, default `x-forwarded-user`), so there is no
  sign-up step. Roles and groups stay local. Enable it only when the app cannot
  be reached except through the proxy.

  A proxy usually authenticates your whole Atlassian organisation, which is
  wider than the site being mirrored, so the mirror admits only:

    * an administrator — seeded (`CM_ADMINS`), admin role, or a member of an
      admin group; and
    * an identity the sync has seen on the site — a member of a group the
      content mentions, or a user named in a space permission or page
      restriction.

  Everyone else gets a `403` page, and no account is created for them. The
  question is answered by `Mirror.identity_known?/1`, which is the best the
  mirror can do: Confluence Cloud has no API that lists a site's users.
  `CM_PROXY_AUTH_MEMBERS_ONLY=false` restores the older behaviour, where the
  proxy's word was enough.

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

### Linking a Confluence identity to an account

One person often holds two Atlassian accounts — a personal one and a guest or
contractor one — and Confluence's content and permissions may name either. Under
*Users & tokens* → *People from Confluence*, each identity the sync has seen can
be **linked** to a mirror account by its e-mail address, and unlinked again.

What the identity carries becomes the account's: its group memberships, the
spaces and pages it is named in, and the content it authored. The rule is the
union — `Accounts.identity_keys/1` answers with every linked identity, so what a
reader may open is everything any of their identities may open, whether they
arrived by a page or by an API token.

Two things are refused: an identity the mirror has never seen (a typo would
otherwise be a grant that silently does nothing — run a sync first), and an
identity another account already holds (two accounts claiming one identity would
be two readers sharing every permission it carries). Linking and unlinking are
in the audit log as `user.identity_linked` / `user.identity_unlinked`.

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
| Webhook answers `429` | the intake cap was hit — 60 deliveries a minute from one address by default; see `/admin/settings` |
| A sync ends `partial` | at least one page failed — read the run's errors on `/admin`; nothing was silently dropped |
| A reader gets `404` for a page that exists in Confluence | a page restriction hides it from that reader; hidden resources are never confirmed with a `403` |

## Where next

The other guides — configuration, operations, API, design notes, developer notes
— are listed in the [README](../README.md#documentation).
