# The public surface: one instance, two audiences

**Status: proposal, nothing implemented.** This file is the argument and the
plan; no route, setting or screen described here exists at HEAD. Where a claim
about today's code decides the design, the file it was checked in is named.

## The ask

One deployment, two audiences:

* **staff** — authenticated by the proxy in front, as today: readers see what
  their mirrored permissions allow, administrators get `/admin`, sync, exports
  and the API;
* **the internet** — anonymous, read-only, the same reader screens and the same
  content rules, with no administration, no sync and no account anything;
* **one unauthenticated path** on the proxy: the public surface, so the skip
  list stops being a growing list of exceptions and becomes one prefix.

The question this document answers: *is that possible, and what would make it
safe?* Short answer: yes, but the price is not in the router — it is in every
URL the public pages emit, including the ones already inside stored page
bodies. Sections [Where the surface comes from](#where-the-surface-comes-from)
and [The URL layer](#4-the-url-layer) are that price, and they decide the shape.

## What already exists, and is reused

The audience question is solved. A reader with no account is already a reader:

| Piece | Where |
| --- | --- |
| the anonymous scope | `Accounts.Scope.for_user(nil)` (`lib/…/accounts/scope.ex`) |
| the anonymous subject the sync mirrors from `anonymousAccess` | `Authorization`, `space_permissions` |
| the rule that keeps silence from meaning "everyone" | `Publishing.public_site?/0` and `Authorization.stranger?/1` |
| redaction seams, each one place | `Publishing.byline/1`, `Publishing.exclude_comments?/0` |
| exports narrowed by the reader | `Export`, pinned by `test/…_web/controllers/access_test.exs` |
| a whole deployment that works this way today | `CM_PUBLIC_SITE=true` |

So the feature is not "read anonymously": that is shipped and tested. The
feature is **two audiences in one instance**, with the anonymous one confined to
a path.

## Threat model: what removing authentication removes

Behind the proxy, the app can assume every request has an identity. On a path the
proxy skips, four assumptions break:

1. **The identity header is not evidence.** `Plugs.ProxyAuth` trusts
   `X-Forwarded-Email` whenever `CM_PROXY_AUTH=true`; that trust rests entirely
   on the mirror being unreachable except through the proxy. oauth2-proxy 7.15
   documents `--skip-auth-strip-headers` (default `true`) as stripping this class
   of header on a skipped route, but the app must not build its authorization
   model on one default of one version.
2. **The session cookie is still sent.** Same origin, `Path=/`, so an
   administrator's cookie arrives on public requests. If a public request reads
   it, the "anonymous" surface silently becomes the staff surface.
3. **Nothing may write.** `/spaces/:key/resync` is a POST inside the reader
   scope; every future write added under a reader path would join a skip list
   automatically if the list is by prefix.
4. **The LiveView socket is a second front door.** Public pages are interactive
   (search, catalogs, presence), so the socket must be reachable unauthenticated
   too.

The design answers each one by construction, not by remembering: the public
scope has no `ProxyAuth` plug, sets `current_user` to `nil` itself, declares only
GET routes, and mounts its LiveViews in their own `live_session`.

## Where the surface comes from

Three ways to tell the app "this request is the public one", and one that only
looks like a choice.

| | Shape | What it costs | What it guarantees |
| --- | --- | --- | --- |
| **A** | **Path prefix** `/public/…`, one proxy, `^/public/` the only content path skipped | every internal URL must carry the prefix — UI, redirects, **and stored page bodies** | the allowlist is a router list; anything not declared is a 404, and a test can enumerate it |
| **B** | **Second door**: a public hostname pointed at a tiny reverse proxy in front of the same app | one more app (a Caddyfile), a trusted header, links and bodies work unchanged | same allowlist, enforced by `conn.host`; but there are now two public components to keep correct |
| **C** | **Second deployment**: today's `CM_PUBLIC_SITE=true` instance for the public site | a second app, database and sync | nothing new to trust — and two copies of the same content to keep alive |
| **D** | **Method-scoped skip list** on the one proxy (`GET=^/spaces/`, …) with `CM_PUBLIC_SITE=true` | one afternoon, no code | **fail-open**: the public and staff surfaces are the same pages, so any reader route added later is public by default |

D is what one can do this afternoon, and it is explicitly *not* recommended as
the destination: a public surface should fail closed. Between A and B, both give
the same property; **B gets it for a fraction of the work** because it never has
to touch a URL. A is what was asked for, and it is buildable — the rest of this
document is A, with the parts B would not need marked.

**Recommendation:** build the surface vocabulary and the route allowlist (both A
and B need them), then choose the door. If "one proxy, one skip rule" is a hard
requirement, take A and budget the URL layer honestly — it is the largest item.

## The design

### 1. Surface as a word the app can say

`Scope` grows one field, and it is set once, by a plug:

```elixir
defstruct user: nil, admin?: false, surface: :site

def for_user(nil), do: %__MODULE__{}
def for_user(%User{} = user), do: %__MODULE__{user: user, admin?: Admins.admin?(user)}

# The public surface is anonymous for everyone, signed in or not.
def public, do: %__MODULE__{surface: :public}
```

`Authorization.stranger?/1` becomes the surface question, and keeps the
whole-deployment flag for `CM_PUBLIC_SITE` deployments:

```elixir
defp stranger?(%Scope{} = scope),
  do: scope.surface == :public or (Publishing.public_site?() and not Scope.signed_in?(scope))
```

One trap to avoid: `Scope.for_user/1` is called in fourteen places. Defaulting
the new field to `:site` keeps them all correct — but it also means a place that
*forgot* to pass the surface looks authenticated-ish rather than failing. So the
public pipeline assigns `Scope.public()` directly and never calls `for_user`.

### 2. The allowlist

The reader routes are declared once and mounted twice, and the public mount is an
explicit list — not "everything in the reader scope minus the admin bits":

```elixir
defmodule ConfluencePhxMirrorWeb.Router do
  pipeline :public do
    plug :accepts, ["html"]
    # LiveView needs a fetched session for its container; the surface plug then
    # ignores everything in it.
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConfluencePhxMirrorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @secure_browser_headers
    plug Plugs.PublicSurface     # surface: :public, current_user: nil
    plug Plugs.Theme
    plug Plugs.SiteContext
    plug Plugs.ReaderRateLimit, scope: :public
  end

  live_session :public_reader,
    on_mount: [{LiveUserAuth, :public}],
    session: {Plugs.PublicSurface, :session, []} do
    scope "/public", ConfluencePhxMirrorWeb do
      pipe_through :public
      public_reader_live_routes()
    end
  end

  scope "/public", ConfluencePhxMirrorWeb do
    pipe_through :public
    public_reader_routes()
  end
end
```

`Plugs.PublicSurface` does exactly this, and nothing else:

```elixir
def call(conn, _opts) do
  conn
  |> assign(:surface, :public)
  |> assign(:current_user, nil)
  |> assign(:current_scope, Scope.public())
  |> delete_session(:user_id)         # belt: a later plug cannot find one
  |> delete_req_header("x-forwarded-email")
  |> delete_req_header("x-forwarded-user")
end

# A live_session's `session:` must not read the socket; it is the same for all visitors.
def session, do: %{"surface" => "public"}
```

The public list, taken from today's reader routes, GET only:

| Surface | Routes |
| --- | --- |
| content | `/`, `/spaces/:key`, `/spaces/:key/overview`, `/spaces/:key/tree/:page_id`, `/spaces/:space_key/pages/:id`, the page slug form, blog posts |
| catalogs (LiveView) | `/spaces`, `/spaces/:key/pages`, `/spaces/:key/blog`, `/spaces/:key/attachments`, `/labels`, `/people`, `/search` |
| navigation | `/recent`, `/labels/:name`, `/about`, `/theme/:name` |
| files | `/attachments/:space_key/:page_id/:attachment_id/:filename`, `/spaces/:key/icon` |
| downloads | `/export.md`, `/export.zip` (page), `/export.zip` (space), `/site.zip` (space) |

Deliberately absent: both resync POSTs, `/session*`, `/profile`, `/mcp` (the
explainer page names the tokens an administrator issues), `/admin*`, `/api*`,
`/wiki*`, `/webhooks`, `/oauth`, `/.well-known`. The attachment route is
duplicated rather than shared, because the staff one runs `ProxyAuth` and
`AutoAdmin`; the public one must not.

### 3. The identity rule

Public requests carry no user, and that is enforced three times over:

* the pipeline has no `ProxyAuth` and no `AutoAdmin`;
* `PublicSurface` assigns `current_user: nil` **after** `fetch_session` and
  deletes the session key and the identity headers;
* `LiveUserAuth.reader/1` — which falls back to `Accounts.ensure_admin!()` when
  `auto_admin` is on (`lib/…_web/live_user_auth.ex`) — must refuse that fallback
  when the session says `"surface" => "public"`. Otherwise a development server
  would hand every visitor an administrator on the public surface.

`Plugs.AutoAdmin` is already refused by a release that mirrors a real site
(`Config.IdentityGuard`), so this is a development-only hole; it is still a hole
worth a test.

### 4. The URL layer

This is the expensive part, and it is why B exists.

**`~p` does not know about the request.** Verified in
`deps/phoenix/lib/phoenix/verified_routes.ex`: the sigil expands to
`unverified_path(endpoint, router, path)` — the endpoint module, not the conn.
Only explicit `unverified_path(conn, …)`/`path(conn, …)` consults
`conn.script_name`, and a plain `scope "/public"` does not set `script_name`
anyway (only `forward` does). There are 141 `~p` call sites in
`lib/confluence_phx_mirror_web` and 69 `<.link>`.

**Redirects leave the surface.** The canonical-page redirect
(`PageController.show/2` → `URLs.content_path/2`), the `/wiki/*` compatibility
redirect, blog-post slug redirects and `ThemeController`'s return path all build
absolute paths. A public visitor following one lands back on the authenticated
door.

**Stored bodies leave the surface.** `Sync.Renderer` rewrites Confluence links to
mirror paths while the page is rendered — `/spaces/…` and
`/attachments/…` (`renderer.ex`, `page_link/3`, `attachment_link/3`). Those bytes
are stored and served as-is, so the first cross-page link a public reader clicks
would leave `/public`.

So the layer has four pieces:

1. **One helper**, and a guard test that makes it the only way:

   ```elixir
   defmodule ConfluencePhxMirrorWeb.Paths do
     @moduledoc "A reader path as this request's surface spells it."

     def path(%{surface: :public}, "/" <> path), do: "/public" <> path
     def path(_assigns, path), do: path
   end
   ```

   Templates write `href={Paths.path(@surface, ~p"/spaces/#{space.key}")}`;
   controllers write the same around `URLs.content_path/2`.

2. **`<.link>` prefixes itself.** The component is redefined in the web's
   component module (which `html_helpers` imports after `Phoenix.Component`) and
   fills `navigate`/`patch`/`href` through `Paths.path/2` when the target is an
   internal path and the request has no `method`. One place instead of 69.

3. **Redirects go through the helper**, and `ThemeController.return_path/2` is
   narrowed from "any same-site path" to "a path on this surface" — otherwise a
   crafted `?redirect=/admin/settings` moves a public visitor to the sign-in
   door.

4. **Stored bodies are rewritten for the public surface**, with the pattern that
   already exists for the static site: `Export.Site.Content.rewrite/2` walks the
   stored HTML and rewrites `href`/`src` with a `:prefix`. A public page view gets
   the same treatment with prefix `/public`, cached by `{page.id, body_hash}` —
   the shape of `Mcp.Markdown`'s Cachex cache, not a new idea.

A test that closes the loop: crawl a rendered public page's internal links and
assert every one starts with the surface prefix. That is the guard against the
next person adding `~p` somewhere the helper is not.

### 5. The LiveView half

Public pages are interactive, so they mount over the socket:

* `live_session :public_reader` carries `session: %{"surface" => "public"}`,
  which is signed into the page's container;
* `LiveUserAuth.on_mount(:public, …)` assigns `Scope.public()` and ignores
  anything the session says about users;
* the socket path must be reachable through the proxy (`^/live/`), which is the
  one place where skipping authentication exposes something that is not a page.

That last point is safe for a reason worth writing down, because it looks
alarming. A LiveView mount takes its module **from the signed session**, and its
route must match both that module and that live_session name
(`deps/phoenix_live_view/lib/phoenix_live_view/channel.ex` →
`Route.live_link_info!/3`). An unauthenticated client cannot mount an admin
screen by sending an admin URL: it would need a session signed for that module,
and only the guarded router issues one. The residual risk is a bug in an
`on_mount` hook, so the hook stays the single authority and the admin hooks keep
their existing "re-read the account on every event" behaviour.

### 6. The proxy

```
OAUTH2_PROXY_SKIP_AUTH_ROUTES = '^/public/|^/assets/|^/images/|^/favicon\.ico$|^/live/'
```

Three notes, all checked against oauth2-proxy 7.15:

* `/assets/`, `/images/` and the favicon are static files served by `Plug.Static`
  before the router; without them the public page is unstyled, because the
  browser fetches them from the same origin the proxy guards.
* `/live/` is the socket. There is no way to have an interactive public page
  without it.
* skip-auth matching uses the decoded path and refuses ambiguous ones (`/public/..`,
  repeated slashes, backslashes), so the exemption cannot be tricked into
  covering `/admin`. Assert the regex in a test that reads
  `deploy/fly/proxy/fly.toml`, so a later edit is a test failure rather than a
  surprise.

Everything else — `/admin`, `/api`, `/wiki`, `/webhooks`, `/oauth`,
`/.well-known`, `/session`, `/health`, `/attachments` (staff) — stays behind the
door.

### 7. Caching, and the price of interaction

An interactive page cannot be shared by a CDN: LiveView needs the session
cookie and the CSRF token, so the response varies per visitor. That is a
deliberate trade — **the public surface is a live, permission-aware site; the
cacheable copy is the static export**, which already exists as a ZIP and can be
served by any static host.

If the public surface should be CDN-cacheable instead, the lever is to make it
static: no LiveView on it, no CSRF, no session cookie, `cache-control: public`.
That removes search and the filter boxes from the public site, which is probably
the wrong trade for documentation.

### 8. The redaction settings, and one sync-time trap

`CM_ANONYMIZE_CONTRIBUTORS` and `CM_EXCLUDE_COMMENTS` are deployment-wide today:
sixteen `Publishing.byline/1` and five `exclude_comments?/0` call sites in
presenters, components, exports and MCP tools. A mixed instance wants them per
surface — names hidden from strangers, names shown to staff — and that is a
mechanical change (pass the scope) but a wide one. **Phase 3**, and until then
the honest statement is: those two settings apply to the whole instance.

The trap is in the listing macros. A dynamic macro's audience is decided when
the page is *expanded at sync time*, not when it is served:
`Sync.DynamicContent.Source.Mirror` asks `Authorization.readable_alongside/2`,
and `unlisted_audience/0` answers `:everyone` unless
`Publishing.public_site?()` is on. On a mixed instance that flag is off, so a
public page could bake in a listing that names a page from a space no stranger
may read — the link would 404, the title would not. The fix is a third,
independent switch (say `CM_PUBLIC_SURFACE=true`) that makes the sync-time
audience conservative, plus a `Sync.Renderer.revision/0` bump so stored pages are
re-rendered — the mechanism that already exists for exactly this.

## What the feature must keep true

Every line here is a test, not an intention.

1. **A public request has no user.** A forged `X-Forwarded-Email` and a valid
   staff session cookie both leave `/public` anonymous.
2. **The public router has no writes.** Only GET/HEAD are declared, and the
   surface plug halts anything else — two independent reasons a POST is a 404.
3. **The allowlist is enumerable.** A test walks `Router.__routes__`, filters the
   public scope, and fails on a route that is not a GET or whose controller is not
   on the reader list. New routes are public only when someone says so.
4. **A stranger's 404 is a 404.** No 403, no sign-in redirect, for a page, an
   attachment or an export.
5. **Nothing on the public surface syncs.** No enqueue, no upstream call: the
   surface cannot change the mirror.
6. **Every internal link carries the prefix** — page chrome, redirects, and the
   body of a page whose stored HTML was written by the sync.
7. **The socket cannot escalate.** An unauthenticated connection cannot mount an
   admin screen; a public session cannot navigate to a staff route.
8. **The proxy skips exactly five patterns**, asserted by a test that reads the
   deployed configuration.

## Work plan

| Phase | What | Why it is separable | Size |
| --- | --- | --- | --- |
| 0 | `Scope.surface`, `Plugs.PublicSurface`, `LiveUserAuth.reader` refusing the dev fallback | no route changes; the suite stays green and `:site` remains the default everywhere | ½ day |
| 1 | router allowlist + `:public` pipeline + 404 for everything else | the security property lands before any link does | 1 day |
| 2 | URL layer: `Paths`, the `<.link>` override, redirects, the crawl test | the largest item; nothing works end to end without it | 1½ days |
| 3 | stored-body rewrite + cache + the sync-time audience switch + `revision` bump | independent of 2, but a public page is broken in spirit without it | 1½ days |
| 4 | public `live_session`, session payload, socket reachability | small once 2 exists | 1 day |
| 5 | proxy skip list, deploy, `routes-auth.md` and `configuration.md` | the deployment half | ½ day |
| 6 | per-surface redaction (optional) | the 20 call sites named above | 1 day |

Phases 0–1 are worth keeping even if the door later turns out to be B: they are
the vocabulary and the allowlist, and B needs both.

## Open questions

* **Is interaction required?** LiveView search and catalogs cost the session
  cookie and CDN-cacheability ([§7](#7-caching-and-the-price-of-interaction)).
* **Should the public surface search at all?** It is a reader screen and narrows
  correctly, but full-text search over internal content is a different promise
  from browsing a published subset.
* **Is a second hostname acceptable?** If it is, B saves most of phases 2–3.
* **Does `/public` get its own rate-limit budget?** It now faces the internet;
  the current limits were sized for people behind a proxy.
* **What is the public surface's canonical URL?** `<link rel=canonical>` and the
  exports should agree on `/public/…`, or the copy will compete with the wiki in
  search engines.
