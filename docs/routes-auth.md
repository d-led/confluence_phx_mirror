# Routes, who may reach them, and what they may see

Three questions, answered by three different things, and they must not be
confused with each other:

| Question | Who answers it | Where |
| --- | --- | --- |
| who is this? | the proxy (or an API token, or a webhook credential) | `deploy/fly/proxy`, `Plugs.ApiAuth`, `Plugs.WebhookAuth` |
| may they have an account here? | the deployment's *policy* | `Accounts.UserPolicy` |
| what may they read? | the permissions the sync mirrored | `Authorization` |

A policy that admits everybody admits them to *public* spaces only: the
permissions replayed by `Authorization` still name who may read what.

The companion test for the combinations below is
`test/confluence_phx_mirror_web/auth_matrix_test.exs` — settings × identities ×
doors, asserted through the real plugs rather than by reading this page.

## Layer 1 — the proxy

Public entry point: the `confluence-mirror` app, oauth2-proxy v7.15.5 with the
GitHub provider. The mirror itself (`confluence-mirror-app`) has **no public
IP** — Flycast only — so every request from the internet arrives through the
proxy, and nothing else can open a connection to the app.

| | |
| --- | --- |
| admitted by the proxy | any GitHub account whose verified e-mail matches `OAUTH2_PROXY_EMAIL_DOMAINS` (shipped: `*`), or a member of `OAUTH2_PROXY_GITHUB_ORG` / `…_GITHUB_TEAM` when those are set |
| sets up the mirror | `X-Forwarded-Email`, `X-Forwarded-User`, `X-Auth-Request-*`, `X-Forwarded-Proto: https`, `X-Forwarded-For` |
| strips | the forwarded identity headers a client sends; it re-sets them from the session, so a reader cannot choose an identity by sending a header |
| skip-auth routes | `/api/…`, `/wiki/rest/api/…`, `/webhooks/…`, `/oauth/(token|register)`, `/.well-known/…` — the paths the app authenticates itself. Shipped as `OAUTH2_PROXY_SKIP_AUTH_ROUTES` in `deploy/fly/proxy/fly.toml`, `fly.demo.toml` and `deploy/k8s/oauth2-proxy.yaml` |
| session | `_oauth2_proxy` cookie, `Secure`, `SameSite=Lax`, 168 h, refreshed hourly |

A path the proxy skips carries **no identity at all**: not `X-Forwarded-Email`,
not `X-Auth-Request-User`, nothing. That is the price of opening it to machines,
and the reason it is safe: on those paths the app's own credential is the only
identity there is, and `CM_PROXY_AUTH` is never consulted — the `:api`,
`:webhook` and `:oauth` pipelines have no `ProxyAuth` plug, and the `:mcp`
pipeline's `McpAuth` falls back to the token.

### Two ways to refuse, and which one a machine sees

"Unauthenticated" has three different shapes, and a client tells them apart by
the status line:

| Route | No credential | Set by |
| --- | --- | --- |
| a browser path the proxy owns | `302` to `github.com/login/oauth/authorize` | oauth2-proxy (`skip_auth_routes` absent) |
| a machine path kept behind the proxy | `401` with a challenge, no redirect | oauth2-proxy, `OAUTH2_PROXY_API_ROUTES` |
| a path the app authenticates | whatever the app answers: `401` + `WWW-Authenticate` (API, MCP), `401`/`404` (webhook intake, off or unsigned), `200` (discovery documents) | the mirror |

So `skip_auth_routes` is the *app-authorized* lever — the proxy gets out of the
way, and the app's Bearer token, signature or PKCE flow decides. `api_routes` is
the *unauthorized* lever: for a machine path you cannot hand to the app (an
upstream that speaks JSON but has no credentials of its own), it replaces the
sign-in redirect with a challenge, which is what a client can act on. Nothing in
this deployment needs it today — every machine path is one the app authenticates
— so it is not shipped; it is the setting to reach for the day one appears.

Two consequences that are easy to trip over:

* **A Confluence delivery only arrives because `/webhooks/` is skipped.** The
  proxy would otherwise answer the delivery with a `302` to GitHub, which
  Confluence reports as a failed delivery. With the skip in place the intake is
  reachable and its own checks decide: `CM_WEBHOOK_ENABLED` (otherwise `404`,
  see [configuration.md](configuration.md#webhooks)) and the signature or
  `CM_WEBHOOK_TOKENS`.
* **A machine client reaches the API with its own token, not a GitHub
  session.** `/api/v1/…` and `/wiki/rest/api/…` are skipped, so
  `Authorization: Bearer <api token>` (or `Basic email:token`) is what the app
  sees first. The proxy no longer answers first, and the app's refusal is a
  `401` with `WWW-Authenticate`, not a login page.

Behind a proxy the mirror trusts the identity header only when told to
(`CM_PROXY_AUTH`), because trusting a header is only defensible when the
endpoint cannot be reached any other way.

## Layer 2 — the app

| Routes | Pipeline | Identity | What can refuse |
| --- | --- | --- | --- |
| `/`, `/spaces/…`, `/people/…`, `/recent`, `/labels/…`, `/search`, `/about`, `/wiki/…`, `/session`, `/subscriptions`, `/theme/…` | `:browser` | session cookie, then the proxy header | `ProxyAuth` (403), `ReaderRateLimit` (429) |
| `/spaces`, `/search`, `/people`, `/labels` (LiveViews) | `:browser` + `live_session :reader` | same | same |
| `/admin/**` | `:browser` + `live_session :admin` | same | `LiveUserAuth` (redirect), `:browser` |
| `/admin/audit/export` | `:browser` | same | the controller's own admin check |
| `/attachments/…`, `/spaces/:key/icon` | `:attachments` | session (optional) | `Authorization` — an unreadable file is `404` |
| `/api/v1/**`, `/wiki/rest/api/**` | `:api` | `Authorization: Bearer`, `Authorization: Basic email:token` | `ApiAuth` (401/403), `ReaderRateLimit` (429) |
| `/api/mcp` | `:mcp` | the mirror's own MCP access token (the pipeline also accepts a proxy-established identity, which the shipped proxy config does not set on this path) | `McpAuth` (401 + `WWW-Authenticate`, so a client starts the OAuth flow), `ReaderRateLimit` (429) |
| `/oauth/register`, `/oauth/token` | `:oauth` | none for registration (public client, PKCE); the code itself for the exchange | `OAuthController` (400 for a bad, reused or expired code) |
| `/oauth/authorize` | `:browser` | session cookie, then the proxy header | the consent screen; `ProxyAuth` |
| `/.well-known/oauth-*` | `:oauth` | none | nothing — it is metadata, and a 401 points a client at it |
| `/webhooks/confluence` | `:webhook` | `X-Hub-Signature-256` HMAC, `X-Webhook-Token`, `Authorization: Bearer`, `?token=` | `WebhookIntake` (404 when off), `WebhookRateLimit` (429), `WebhookAuth`, `WebhookController` (401/503) |
| `/health` | `:health` | none | nothing — it answers whether the process is alive |
| `/api/docs`, `/api/openapi.json` | `:browser` / `:docs` | none | `CM_API_DOCS` (404 when off) |

Identity is resolved **once per request** (`Scope.for_user/1`) and carried in
`conn.assigns.current_scope`; controllers and LiveViews read it back with
`Scope.from_assigns/1` instead of asking again.

## Admission: may this identity have an account?

`Accounts.UserPolicy.allows?(identity, purpose)` — one question, one boolean,
asked at two doors (`:proxy`, `:sign_in`). Two policies ship:

| Policy | Name (`CM_USER_POLICY`) | Admits |
| --- | --- | --- |
| `NewUsersCanReadPublicSpaces` | `new_users_can_read_public_spaces`, alias `allow_all` | everybody who arrives |
| `ReadersMustExistInConfluence` | `readers_must_exist_in_confluence`, alias `members_only` | only identities with a reason: a mirror administrator, a person a space permission or page restriction names, the author of a page or a comment, a member of a group the sync lists, or a member of a group the identity provider asserts **and** the site lists |

`CM_USER_POLICY` may also be `{:any_of, […]}` / `{:all_of, […]}` in config, so
"an administrator, or anybody on the operator's allow-list, or anybody the site
names" composes without the policies knowing about each other.

When no policy is named, the two older switches stand in — the same question
asked per transport, kept for deployments that set them:

| Setting | Door | Implied policy |
| --- | --- | --- |
| `CM_PROXY_AUTH_MEMBERS_ONLY` (default `true`) | `:proxy` | `members_only` when true, `allow_all` when false |
| `MIRROR_SELF_SIGNUP` (default `false`) | `:sign_in` | `allow_all` when true, `members_only` when false |

Naming a policy replaces **both**: one deployment, one answer. A typo in
`CM_USER_POLICY` stops the boot rather than quietly widening the audience.

Precedence, in order:

1. **A disabled account is nobody** — banned, switched off here, deleted on the
   site, or deactivated on the site (unless
   `MIRROR_ALLOW_SITE_DISABLED_READERS=true`). No policy can undo that, and the
   session plug, the API and the webhook route all agree.
2. **The policy decides** whether an account exists.
3. **`Authorization` decides** what it can read.

## Authorization: what an admitted reader may see

Mirrored from Confluence by the sync, replayed per request:

| Subject | Rule |
| --- | --- |
| space | its `read` permissions name groups or people; a space with none is open |
| page | page restrictions narrow the space; an unrestricted page inherits it |
| personal space (`~accountid`) | belongs to the account the key names — owner only |
| administrator | reads everything, including restricted and personal content |
| no account at all | the public spaces |

A refusal is a **404, not a 403**: a restricted page and a page that was never
mirrored answer identically, so the mirror does not confirm that content exists.
The one exception is the proxy door, which answers `403` when the *policy*
refuses an identity before any content is chosen.

## Administration

`Accounts.Admins` — three sources, first match wins:

| Source | How | Notes |
| --- | --- | --- |
| `role` | `admin` on the account, set in `/admin/users` | revocable |
| `group` | membership of a group named in `CM_ADMIN_GROUPS` | membership comes from the sync, never from what a reader types |
| `seed` | the e-mail is listed in `CM_ADMINS` | a seeded address may sign in even when self sign-up is closed |

Seeded administrators and the local bootstrap account cannot be demoted or
deleted through the UI (`Admins.protected?/1`), so a deployment cannot lock
itself out.

Admin screens (`live_session :admin`) redirect a signed-in non-administrator to
`/` with "Administrator access required", and a signed-out visitor to
`/session`. The audit export asks the same question itself, because it is a
plain stream rather than a LiveView.

## Groups are three different things

This is where most confusion lives — three "groups" reach the mirror and none of
them is a group the mirror owns:

| Group | Where it comes from | What it can decide |
| --- | --- | --- |
| Confluence group | synced membership (`/rest/api/user/memberof`) | page restrictions, space permissions, `CM_ADMIN_GROUPS` |
| identity-provider group | asserted by the proxy in `CM_PROXY_AUTH_GROUPS_HEADER`, e.g. `X-Forwarded-Groups` | **nothing by itself** — only `ReadersMustExistInConfluence`, and only for a group name the site also lists *and* a person the site also lists |
| mirror role / seed | this deployment (`role`, `CM_ADMINS`) | administration, and admission for a seeded address |

An asserted group is a claim by whoever runs the proxy. The mirror treats it as
one: it checks the claim against the membership the sync mirrored and ignores
groups it has never seen. With `CM_PROXY_AUTH_GROUPS_HEADER` unset, asserted
groups are not read at all — the proxy may send them, the mirror will not look.

## Settings, one line each

| Variable | Default | Effect |
| --- | --- | --- |
| `CM_PROXY_AUTH` | off | trust `CM_PROXY_AUTH_HEADER` as the reader's identity |
| `CM_PROXY_AUTH_HEADER` | `x-forwarded-email` | which header names the reader |
| `CM_PROXY_AUTH_NAME_HEADER` | `x-forwarded-user` | which header names the display name |
| `CM_PROXY_AUTH_GROUPS_HEADER` | – | which header carries asserted groups (unset = ignore them) |
| `CM_PROXY_AUTH_MEMBERS_ONLY` | `true` | the `:proxy` door's policy when no policy is named |
| `MIRROR_SELF_SIGNUP` | `false` | the `:sign_in` door's policy when no policy is named |
| `CM_USER_POLICY` | – | names the policy for **both** doors |
| `CM_ADMINS` | – | seeded administrator e-mails |
| `CM_ADMIN_GROUPS` | – | synced groups that grant administration |
| `MIRROR_AUTO_ADMIN` | off | dev/test only: every visitor is the bootstrap administrator; a production release refuses to start with it unless the source is the demo |
| `MIRROR_ALLOW_SITE_DISABLED_READERS` | `false` | a reader the site deactivated keeps access |
| `CM_TRUST_PROXY_HEADERS` | off | rate-limit buckets key on the last `X-Forwarded-For` hop instead of the proxy's address |
| `CM_WEBHOOK_ENABLED` | `true` | the intake answers at all (off = the endpoint's own 404) |
| `CM_WEBHOOK_REQUIRE_SIGNATURE` | `false` | a delivery must present a valid signature or token |
| `CM_WEBHOOK_TOKENS` | – | `receiver=token,…` for senders that cannot compute an HMAC |
| `MIRROR_ALLOW_UNSAFE_IDENTITY` | – | the acknowledgement `Config.IdentityGuard` demands before a production release honours `CM_PROXY_AUTH`, `MIRROR_AUTO_ADMIN` or `MIRROR_SELF_SIGNUP` while mirroring a real site |

`Config.IdentityGuard` is the last word on the shortcuts: in a production
release, with a real Confluence source, they are refused unless
`MIRROR_ALLOW_UNSAFE_IDENTITY` is set. The demo source allows them, which is why
the demo deployment needs no acknowledgement.

## Combinations worth knowing

| Settings | Identity | Outcome |
| --- | --- | --- |
| `CM_PROXY_AUTH=false`, header sent | proxy header | header ignored, nobody signed in, no account created |
| `CM_PROXY_AUTH=true`, `allow_all` | unknown e-mail | account created, public spaces only |
| `CM_PROXY_AUTH=true`, `members_only` | unknown e-mail | `403`, no account |
| `CM_PROXY_AUTH=true`, `members_only`, `CM_ADMINS=them` | that e-mail | admitted — a seeded administrator may sign in even when the site never names them |
| `CM_USER_POLICY=allow_all`, `CM_PROXY_AUTH_MEMBERS_ONLY=true` | unknown e-mail | admitted — a named policy replaces both switches |
| `CM_USER_POLICY=members_only`, `MIRROR_SELF_SIGNUP=true` | unknown e-mail at the sign-in door | refused — same reason, other direction |
| any policy, `set_disabled(user, true)` | that account, any door | refused: at the proxy door `403`, in a session nobody, at the API `403` |
| `allow_all` | admitted reader | reads public spaces; a restricted page is `404` for them |
| `CM_WEBHOOK_ENABLED=false` | any delivery | the endpoint's own `404`, nothing stored |
| `CM_WEBHOOK_ENABLED=true`, `CM_WEBHOOK_TOKENS=confluence=t` | `X-Webhook-Token: t` | `202`, the page is queued |
| API, `MIRROR_AUTO_ADMIN=false` | no credentials | `401` with `www-authenticate` |
| API, any | a `webhook`-scoped service token | `401` — a token opens the scope it was issued for and nothing else |
