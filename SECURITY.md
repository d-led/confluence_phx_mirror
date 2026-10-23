# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting — **Security** tab →
**Report a vulnerability** — rather than a public issue. That keeps the report
and the fix private until a release exists. Expect an answer within a week; if
the report is about mirrored content rather than the mirror, it is probably a
question for whoever runs the Confluence site.

## What the mirror assumes

* **It reads, never writes.** Content only changes through a sync that reads a
  source over the network; there is no upload, edit or write-back path.
* **It serves Confluence's own rendering.** Pages are stored as the source's
  sanitised `export_view`; macros that need a browser are resolved from the
  mirror's own data or reported as unavailable rather than faked.
* **It replays the source's permissions.** Page restrictions and (where the
  source supplies them) space permissions decide what a reader may see. A hidden
  page is a `404`, not a locked page.
* **Secrets come from the environment.** There is no secret in the repository or
  in the release; `DATABASE_URL`, `SECRET_KEY_BASE`, `CM_ATL_TOKEN` and the SMTP
  credentials are read at boot. `.env`, `deploy/k8s/secret.yaml` and the media
  blob root are gitignored.
* **Trusting an identity header is a deployment decision.** `CM_PROXY_AUTH=true`
  accepts the reader's identity from `X-Forwarded-Email`. It is only safe when
  the mirror has no public address and a proxy in front sets that header —
  [deployment.md](docs/deployment.md) is explicit about how both shipped
  configurations arrange that, and `Config.IdentityGuard` refuses the shortcut
  in a production release unless the source is the demo snapshot or the operator
  acknowledges it with `MIRROR_ALLOW_UNSAFE_IDENTITY`.

## What the shipped deployments do for you

* The container runs as an unprivileged uid (`10001`), with no shell tooling
  beyond what BEAM needs, and CI fails if the image's uid is `0`.
* CI scans the image with Trivy on every change: anything fixable at CRITICAL or
  HIGH fails the build.
* The mirror's port is not published. On Fly it is a Flycast-only app with
  `--no-public-ips`; on Kubernetes a NetworkPolicy admits only the proxy's pods.
* The proxy is the only public address, terminates TLS, and strips the identity
  headers a client sends before setting them from its own session.

## Known limitations

[design-notes.md](docs/design-notes.md) lists what the mirror deliberately does
not do — no page history, no write-back, no re-implementation of browser-only
macros. Content that Confluence itself would show to a reader is what the mirror
shows; a page that the site's own sanitising lets through arrives as it is.
