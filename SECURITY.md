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
| **Trusting an identity header is a deployment decision** | `CM_PROXY_AUTH=true` accepts the reader from `X-Forwarded-Email`. It is only safe when the mirror has no other address and a proxy sets that header — see [deployment.md](docs/deployment.md). `Config.IdentityGuard` refuses the shortcut in a production release unless the source is the demo or the operator sets `MIRROR_ALLOW_UNSAFE_IDENTITY` |

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

## Known limitations

[design-notes.md](docs/design-notes.md#known-limitations) lists what the mirror
deliberately does not do — no page history, no write-back, no re-implementation
of browser-only macros.

Two edges are worth knowing when you reason about what a reader can see:

* **`include`-family macros are forwarded as the source rendered them**, without
  re-checking who may read the included page.
* **Confluence Cloud exposes space permissions as writes only**, so a space whose
  source cannot report them stays open. Page restrictions are mirrored.
