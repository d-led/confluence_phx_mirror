# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting — **Security** tab → **Report a
vulnerability** — not a public issue. That keeps the report and the fix private
until a release exists.

Expect an answer within a week. If the report is about *mirrored content* rather
than the mirror, it is usually a question for whoever runs the Confluence site.

## What the mirror assumes

| Assumption | What it means |
| --- | --- |
| **It reads, never writes** | content changes only through a sync that reads a source; there is no upload, edit or write-back path |
| **It serves the source's rendering** | pages are stored as the source's sanitised `export_view`; macros that need a browser are resolved from the mirror's own data or reported as unavailable, never faked |
| **It replays the source's permissions** | page restrictions and (where the source supplies them) space permissions decide what a reader may see; a hidden page is a `404`, not a locked page |
| **Secrets come from the environment** | nothing secret is in the repository or the release: `DATABASE_URL`, `SECRET_KEY_BASE`, `CM_ATL_TOKEN` and the SMTP credentials are read at boot. `.env`, `deploy/k8s/secret.yaml` and `/var/` (the blob root) are gitignored |
| **Trusting an identity header is a deployment decision** | `CM_PROXY_AUTH=true` accepts the reader from `X-Forwarded-Email`, and `CM_PROXY_AUTH_MEMBERS_ONLY` — on by default — still refuses an address the site never names. It is only safe when the mirror has no other address and a proxy sets that header — see [deployment.md](docs/deployment.md). With `MIRROR_AUTO_ADMIN` and `MIRROR_SELF_SIGNUP` it is one of three switches that hand out an identity without a sign-in, so a production release that mirrors anything but the demo **fails to boot** with one of them on unless `MIRROR_ALLOW_UNSAFE_IDENTITY=1` says so deliberately (`Config.IdentityGuard`), and the refusal names the switch it refused |

## What the shipped deployments do for you

* **Unprivileged.** The container runs as uid/gid `10001` with no shell tooling
  beyond what BEAM needs, and CI fails unless `id -u` is exactly `10001`.
* **Scanned.** CI runs Trivy on every change: anything fixable at CRITICAL or
  HIGH fails the build.
* **Unreachable directly.** The mirror's port is not published. On Fly it is a
  Flycast-only app (`--no-public-ips`); on Kubernetes a NetworkPolicy admits only
  the proxy's pods.
* **One public door.** The proxy terminates TLS and strips the identity headers a
  client sends before setting them from its own session.
* **The identity shortcut is asked for, not inherited.** The reference proxy sets
  `CM_PROXY_AUTH` *and* `MIRROR_ALLOW_UNSAFE_IDENTITY=1`, because a release that
  mirrors a real site cannot claim the demo's exemption: the second line is the
  deliberate act the boot check exists to force, and it is visible in the app's
  own configuration rather than implied by the first.

## Known limitations

[design-notes.md](docs/design-notes.md#known-limitations) is the one list of what
the mirror deliberately does not do — no page history, no write-back, no
re-implementation of browser-only macros — and it is also where a dependency
advisory this project lives with is written down, one entry each with the reason
it is tolerated. GitHub's dismissal is capped at 280 characters, so it links
there instead of arguing the case itself.

Two edges matter when you reason about what a reader can see:

* **`include`-family macros.** An include the source inlined into the page
  arrives as words in that page's body, and there is nothing left to check. One
  the mirror draws itself is drawn only when the page named has readers at least
  as wide as the host page's, so a restricted page is never pulled into an open
  one by the mirror's own rendering.
* **Space permissions exist only where the source reports them.** Confluence
  Cloud has no API that lists them, so a Cloud mirror replays page restrictions
  and whatever space permissions the source was able to supply — no more.
