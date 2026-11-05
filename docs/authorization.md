# Authorization, in one screen

**Read this first.** The deep version is [routes-auth.md](routes-auth.md); the
settings are in [configuration.md](configuration.md#publishing).

---

## 60-second version

1. **Someone gets in.** Proxy header, magic-link session, or API token.
   Whether an unknown identity is welcome is `CM_USER_POLICY`.
2. **What they may open** is replayed from Confluence: page restriction →
   space permission → a space with no rows is open *to admitted readers*.
3. **A stranger** (no account) is a reader only if `CM_PUBLIC_SITE=true` — and
   then only of the spaces in `CM_PUBLIC_SPACES`, if that is set.
4. **A hidden thing is a 404**, never a 403.
5. **A page a stranger may open names nobody** — that is not a switch.

---

## The rule: every gate must pass

| Gate | Passes when |
| --- | --- |
| administrator | always — an admin sees everything, personal spaces included |
| the space | it is **not** personal (a personal space is its owner's alone), **and** either it lists read permissions that match you, or it lists none and you are not a stranger |
| the page | it has no read restrictions, or one that matches you |

A match is any identity you carry: e-mail, the identity you signed in with, a
linked Confluence identity, or a group the mirror knows — plus the two words
the site itself uses, `authenticated` and `anonymous`.

Why "lists none" splits: a permissions read that failed, or a space the sync
never stored, looks exactly like "everyone". Fair behind a proxy, a leak on the
internet — so a space with no rows is open to an **admitted reader** and closed
to a **stranger**.

**Overlays:** a grant (`granted_by_id`) lets one more reader in; a removal
(`revoked_by_id`) keeps one out. A space or page left with only removals is
**closed**, not open.

---

## Pick your deployment

| I want… | Set | A stranger sees |
| --- | --- | --- |
| Staff only, behind the proxy | *(nothing)* | Nothing: there are no strangers |
| A public documentation site | `CM_PUBLIC_SITE=true` | Every space the site marks `anonymousAccess` |
| …but only some spaces | `CM_PUBLIC_SITE=true` `CM_PUBLIC_SPACES=ENG,OPS` | Those spaces; anything else is 404 |
| …and no names or comments | `CM_ANONYMIZE_CONTRIBUTORS=true` `CM_EXCLUDE_COMMENTS=true` | As above, without them |
| Two audiences, one proxy, one app | not built — [public-surface.md](public-surface.md) | — |

`CM_PUBLIC_SPACES` **narrows** `CM_PUBLIC_SITE`; it never grants what the
site's own permissions restrict.

---

## Who counts as a stranger

`Scope.for_user(nil)` — the same scope a signed-in reader gets, with no user.

A stranger on a **public deployment** is held to what the site actually says:
a synced permission row with the `anonymous` subject. Anything else is 404.

`CM_PUBLIC_SITE` and `CM_PUBLIC_SPACES` are read at **boot**: changing them is
a deploy, and the log names what it resolved
(`publishing: public spaces ENG, OPS: …`).

---

## Two families of seams

**One decision, one place.**

| Question | Ask | Reaches |
| --- | --- | --- |
| may this reader open this page? | `Authorization.can_read_page?/2` | page view, attachments, exports, API |
| which spaces? | `Authorization.readable_spaces/1` | switcher, `/spaces`, home rail |
| narrow a query | `Authorization.restrict_spaces/2`, `restrict_pages/2` | catalogues, sidebar, search |
| narrow a list already in hand | `Authorization.readable_pages/2`, `readable_results/2` | archives, search results |
| may this reader see names? | `Publishing.identities?/1` | byline, comments, presence, `/people`, catalogue, search's name menu |
| are comments published at all? | `Publishing.exclude_comments?/0` | the page's comment section, comment search hits and their snippets, exports, MCP |
| may the **stored body** name people? | `Publishing.identities_in_space?/1` | `contributors`, `user-profile`, `profile-picture`, exports |

Why two identity questions: a page is drawn per request, so it can answer per
reader. A body is rendered once at sync time and served to everybody, so it must
be stored in the **stranger's** shape. A signed-in reader of a public page
therefore loses the names inside its macros and keeps the ones in its chrome.

---

## Failure modes, and what catches them

| Mistake | What happens |
| --- | --- |
| a typo in `CM_PUBLIC_SPACES` | boot warning: "not a mirrored space" |
| a list without `CM_PUBLIC_SITE` | boot line says `inert without CM_PUBLIC_SITE` |
| a route added later that leaks | hidden is 404, and `access_test.exs` walks the routes as a stranger |
| a cached reader's copy shown to a stranger | the ETag names three shapes: `admin` / `reader` / `anonymous` |
| a macro that names people | decided by the page's space at render time, `revision/0` re-reads bodies |

---

## What it cannot do

- **A page's own prose is not scrubbed.** Names in a sentence, a screenshot, an
  attachment: those stay. The mirror removes the identities *it* draws.
- **Titles, space names and recent changes still say which documents exist.**
- **A personal space is never public**, whatever the list says.
- **The API and MCP are always authenticated** — a caller is a reader or an
  admin, never a stranger.

---

## The tests that pin it

| File | Pins |
| --- | --- |
| `test/confluence_phx_mirror/authorization_test.exs` | the gates, the overlays, the stranger |
| `test/confluence_phx_mirror/publishing_test.exs` | the switches, the list, the boot report |
| `test/confluence_phx_mirror_web/controllers/access_test.exs` | 404s across routes, exports |
| `test/confluence_phx_mirror_web/controllers/public_space_identity_test.exs` | a stranger sees no name; a reader does |
| `test/confluence_phx_mirror/sync/dynamic_content/*_test.exs` | what a stored body may name |
