# Deploying the mirror

Two deployment configurations ship with the repository, both of the same shape:

```
                 public                       private
  reader ──▶ oauth2-proxy ──X-Forwarded-Email──▶ mirror ──▶ Postgres
             (only public IP)                  (no public IP)   └─▶ blob volume
```

| | Fly.io | Kubernetes |
| --- | --- | --- |
| configuration | [`fly.toml`](../fly.toml) + [`deploy/fly/proxy`](../deploy/fly/proxy) | [`deploy/k8s`](../deploy/k8s) |
| front door | app `confluence-mirror` (oauth2-proxy, the only public IP) | `oauth2-proxy` Deployment + Ingress |
| the mirror | app `confluence-mirror-app`, Flycast only | `confluence-mirror` Deployment + ClusterIP Service |
| database | app `confluence-mirror-db` (Postgres 18, attached) | managed Postgres |
| migrations | `[deploy] release_command = "/app/bin/migrate"` | the `confluence-mirror-migrate` Job |
| attachments | Fly volume `mirror_blobs` | PVC `mirror-blobs` |
| clustering | `FLY_APP_NAME.internal` | headless Service via `DNS_CLUSTER_QUERY` |
| deploy it | `./scripts/fly-deploy.sh live` | `kubectl apply -f …` |

### Which Fly file is which

One rule: **a directory you would deploy from holds one `fly.toml`, and that
file is the app that directory is about.** `fly deploy` reads `fly.toml` from
the directory it is given, so the default is always the right app and nothing
has to be remembered.

| file | app | what it is |
| --- | --- | --- |
| `fly.toml` | `confluence-mirror-app` | **the live mirror of a real site — this is the one that is deployed** |
| `deploy/fly/proxy/fly.toml` | `confluence-mirror` | its oauth2-proxy front door (public) |
| `deploy/fly/demo/fly.toml` | `confluence-mirror-demo-app` | the self-contained demo (`CM_SOURCE=demo`, no credentials) |
| `deploy/fly/proxy/fly.demo.toml` | `confluence-mirror-demo` | the demo's proxy |

The demo pair is the only thing that is not a default, and its files say
`demo` in their names: `fly deploy --config deploy/fly/demo/fly.toml`, and
`fly deploy deploy/fly/proxy --config deploy/fly/proxy/fly.demo.toml`. The two
backends are deployed from the repository root, because the Dockerfile that
builds the release needs the whole project as its build context; the two
proxies are deployed from `deploy/fly/proxy`, where their Dockerfile is.

`scripts/fly-deploy.sh live` ships a version to the live pair;
`scripts/fly-deploy.sh demo` to the demo pair. Neither creates anything: what
has to exist first is `scripts/fly-provision.sh live`, or `… demo`.

Nothing here is required by the application: it is a 12-factor release, and
[operations.md](operations.md) describes the environment contract any process
manager can satisfy. These two are the configurations that are exercised.

## The image

```bash
docker build -t confluence-mirror --build-arg VERSION="$(git describe --tags --always)" .
docker run --rm -e DATABASE_URL=… -e SECRET_KEY_BASE=… confluence-mirror /app/bin/migrate
docker run -p 4000:4000 -e … confluence-mirror          # /app/bin/server
```

What the image promises:

* **One release, no build tooling.** Node installs the browser dependencies,
  the Elixir image compiles and bundles, and the runtime stage carries the
  release plus BEAM's shared libraries — about 160 MB, no compiler, no Node, no
  git in it.
* **Unprivileged.** Everything runs as uid/gid `10001` (`app`), so
  `runAsNonRoot` can be checked rather than assumed. CI asserts both the
  non-root uid and that Trivy finds nothing fixable at CRITICAL or HIGH.
* **Multi-arch.** A published tag is one image index with `linux/amd64` and
  `linux/arm64` manifests, so an Apple Silicon laptop and an arm64 VM pull a
  native build while x86 servers pull theirs. CI builds and checks amd64 on the
  runner's own architecture; the arm64 half is compiled under QEMU on
  publication only, so pull requests do not pay for it.
* **One writable directory.** `/app/var/mirror` holds the blob store
  (`MIRROR_BLOB_ROOT`); mount a volume there. The rest of `/app` is read-only
  for the app user, which is why the Kubernetes manifests can set
  `readOnlyRootFilesystem` and give `/tmp` an `emptyDir`.
* **Migrations are not the boot.** `CMD` is `/app/bin/server`; `/app/bin/migrate`
  is a separate step, so two instances never migrate at once.
* **Pinned bases.** `ELIXIR_VERSION`, `OTP_VERSION`, `DEBIAN_VERSION` and
  `NODE_VERSION` are build arguments with dated tags. Debian trixie rather than
  bookworm: the same image scanned with one CRITICAL and 59 HIGH findings on
  bookworm and with none of either on trixie, all of them without a fix either
  way. What remains unfixed is the base distribution's backlog, which is why CI
  scans with `ignore-unfixed: true` and fails on anything a rebuild could fix.

### What the build knows about itself

The image carries one extra file, `priv/build_info.json`, written by
`mix build.info` before `mix release`:

```json
{"version": "v1.2.3", "revision": "3f2a1c9b8e7d…", "built_at": "2026-10-23T14:02:19Z",
 "ci": {"provider": "github", "workflow": "ci", "run_number": "42", "run_url": "…/runs/42"}}
```

An administrator sees it in the admin footer as `v1.2.3+3f2a1c9`, with the run
as a `ci #42` link when a pipeline built the image; readers do not. The boot log
says the same in one line, so a log from a container that started for someone
else's deploy can be identified. A checkout that no build touched — `mix
phx.server`, the test suite — says `dev`, because that is what it is: a
gitignored file that only a build writes.

| Where | `version` | `revision` | `ci` |
| --- | --- | --- | --- |
| `docker build --build-arg VERSION=… --build-arg REVISION=…` | the argument | the argument | from `CI_*` build arguments |
| `scripts/mix_release.sh` | `git describe --tags --always --dirty` | short commit | none |
| development, tests | `dev` | none | none |

`ENV` cannot stand in for this: what the footer reports is a property of the
bytes in the image, not of how someone started it.

## Identity: what the proxy sets, what the mirror reads

The proxy authenticates the reader and hands the mirror an identity header.
This is the contract between the two halves, and it is worth knowing exactly:

| Hop | Header | Who sets it | Who reads it |
| --- | --- | --- | --- |
| reader → proxy | session cookie (`_oauth2_proxy`) | oauth2-proxy | oauth2-proxy |
| proxy → mirror | `X-Forwarded-Email` | oauth2-proxy (`--pass-user-headers`) | `Plugs.ProxyAuth` → `CM_PROXY_AUTH_HEADER` (default `x-forwarded-email`) |
| proxy → mirror | `X-Forwarded-User` | oauth2-proxy | display name, `CM_PROXY_AUTH_NAME_HEADER` (default `x-forwarded-user`) |
| proxy → mirror | `X-Forwarded-Proto: https` | oauth2-proxy (`--reverse-proxy`) | `force_ssl` in `config/prod.exs` |
| proxy → mirror | `X-Forwarded-For` | oauth2-proxy appends | the reader rate limit, with `CM_TRUST_PROXY_HEADERS=true` |

Four consequences follow, and each is a setting in both configurations:

1. **`CM_PROXY_AUTH=true` is only safe because the mirror has no public
   address.** Anyone who can reach the mirror's port directly can name
   themselves. On Fly that is `--flycast --no-public-ips`; on Kubernetes it is
   the NetworkPolicy admitting only the proxy's pods. A production release also
   refuses the setting unless the source is the demo snapshot or the operator
   sets `MIRROR_ALLOW_UNSAFE_IDENTITY=1` (`Config.IdentityGuard`).
2. **Without `X-Forwarded-Proto`, `force_ssl` redirects the proxy to itself.**
   The proxy forwards an HTTP request to the mirror; the mirror sees plain HTTP,
   answers `301 https://…`, the proxy passes the redirect on, forever. That is
   why `OAUTH2_PROXY_REVERSE_PROXY=true` is not optional here, and why every
   ingress controller has to send the header.
3. **`/health` is excluded from `force_ssl`.** Probes arrive from a kubelet or
   from Fly's checker over plain HTTP and cannot send the header; they are
   asking whether the process is alive, and a `301` would only ever answer
   "not quite".
4. **The reader rate limit keys on the reader, not the proxy.**
   `CM_TRUST_PROXY_HEADERS=true` makes it use the last `X-Forwarded-For` entry —
   the hop the proxy observed, which a client cannot write.

Because the proxy owns the browser paths, the JSON API and the
Confluence-compatible REST endpoints would otherwise be behind GitHub sign-in
too. They are not: the shipped proxy config skips the paths the app
authenticates itself — the API, the MCP endpoint and its OAuth halves, the
webhook intake — and leaves `/oauth/authorize` and the reading surface to the
proxy. [routes-auth.md](routes-auth.md) has the exact set, and explains the
difference between the proxy's `302`, an `api_routes` `401`, and the app's own
refusal.

### Verified, not assumed

Both hops were exercised against the built image before this was written
(oauth2-proxy v7.15.5, 2026-10-23):

| Check | Result |
| --- | --- |
| `GET /health` with no forwarded proto | `200` |
| `GET /` with `X-Forwarded-Proto: https` | `200` |
| `GET /` without it | `301` to `https://…/` |
| `X-Forwarded-Email: jane@example.com` | account provisioned, `display_name` from `X-Forwarded-User` |
| same header, `CM_ADMINS=ops@example.com` | `/admin` `200` for ops, `302` for jane, `302` for nobody |
| unauthenticated reader through the proxy | `302` to `github.com/login/oauth/authorize` |
| request through the proxy with edge `X-Forwarded-Proto: https` | `200` (no redirect loop) |
| client-supplied `X-Forwarded-Email` through the proxy | stripped — identity only comes from a session |

The last row is the one that matters for the threat model: a reader cannot
choose their own identity by sending the header, because oauth2-proxy removes
the forwarded identity headers a client sends and re-sets them from the session.

## Fly.io

Two scripts, one per question. Provisioning is everything that exists once:

```bash
CM_CONFLUENCE_SITE=https://acme.atlassian.net \
CM_ATL_EMAIL=me@acme.com \
CM_ATL_TOKEN=… \
OAUTH2_PROXY_CLIENT_ID=… OAUTH2_PROXY_CLIENT_SECRET=… \
./scripts/fly-provision.sh live
```

That creates both apps (the mirror with no public address, its oauth2-proxy
with the only one), `fly postgres create` and attach, the blob volume, and the
secrets an app cannot boot without: `SECRET_KEY_BASE`, `RELEASE_COOKIE`, the
proxy's cookie secret, the Confluence credentials. Re-running it is safe —
every step finds what exists and says so — and it changes nothing, because
rotating a secret is a decision (`fly secrets set`), not a side effect of a
deploy.

Deploying is everything that happens per version, and needs no credentials:

```bash
./scripts/fly-deploy.sh live            # mirror, then its front door
./scripts/fly-deploy.sh live --check    # verify only: would this deploy?
./scripts/fly-deploy.sh live --sync     # …and enqueue a full snapshot
```

It refuses before building anything if an app or a secret is missing, and
names the provisioning command that puts it there. It deploys the mirror
first: the proxy's upstream is the mirror's Flycast address, so a proxy
released first answers 502.

The demo pair is the same two commands with `demo`, and its `DATABASE_URL` is
one you bring (`./scripts/fly-provision.sh demo` reads it from the
environment). The GitHub OAuth app's callback URLs are
`https://confluence-mirror.fly.dev/oauth2/callback` and
`https://confluence-mirror-demo.fly.dev/oauth2/callback`.

Details that are easy to get wrong:

* **`fly deploy --flycast --no-public-ips --ha=false`** for the mirror. Without
  `--no-public-ips` Fly allocates a shared IPv4, and the identity header becomes
  forgeable by anyone who finds the hostname.
* **`RELEASE_COOKIE` is a secret, set once.** Regenerating it makes the Machines
  strangers to each other until they restart together.
* **One volume, one Machine.** A Fly volume is bound to a Machine; `--ha=false`
  keeps the deployment honest about that. Two Machines would need a shared blob
  store, and the mirror writes attachments to the filesystem.
* **Ports.** The proxy listens on 4180 and is the `http_service`; the mirror
  listens on 8080 inside the private network, `force_https = false` because
  Flycast is HTTP-only.
* **`OAUTH2_PROXY_EMAIL_DOMAINS="*"`** admits any GitHub account. Narrow it to a
  domain, or add `OAUTH2_PROXY_GITHUB_ORG` / `OAUTH2_PROXY_GITHUB_TEAM`.
* **The trusted-proxy warning.** oauth2-proxy v7.15.5 logs a warning that
  `--reverse-proxy` trusts `X-Forwarded-*` from any connecting address. On Fly
  the only address that can connect is Fly's edge, so this is what the platform
  intends; setting `OAUTH2_PROXY_TRUSTED_PROXY_IP` to a narrower CIDR is an
  option when deploying behind a proxy you control.

## Kubernetes

```bash
kubectl apply -f deploy/k8s/secret.yaml           # from secret.example.yaml
kubectl apply -f deploy/k8s/confluence-mirror.yaml
kubectl apply -f deploy/k8s/oauth2-proxy.yaml
```

* **Storage.** The PVC is `ReadWriteMany` because more than one replica has to
  see the same attachment bytes. With a `ReadWriteOnce` class, keep
  `replicas: 1` — the mirror serves attachments from the filesystem, and a
  reader routed to the other replica would get a `404`.
* **Probes.** Readiness is `GET /health` (it returns `503` when Postgres is
  unreachable); liveness is a TCP check, so a database blip does not restart
  healthy pods; a startup probe covers the first boot.
* **Identity.** `CM_PROXY_AUTH=true` plus the NetworkPolicy that admits only
  `app.kubernetes.io/name=oauth2-proxy` on port 4000. Do not expose the mirror's
  Service through an Ingress.
* **`PHX_HOST`** must be the public hostname (`mirror.example.com` above),
  because absolute URLs and secure cookies are built from it.
* **Ingress.** Any controller works as long as it terminates TLS and forwards
  `X-Forwarded-Proto`; the manifest carries nginx annotations and a `mirror-tls`
  secret to point at your certificate.

## Clustering

`rel/env.sh.eex` names the node for the platform it finds itself on, and
`DNSCluster` (supervised in `ConfluencePhxMirror.Application`) joins the peers
`DNS_CLUSTER_QUERY` resolves to:

| Platform | Node name | Query |
| --- | --- | --- |
| Fly.io | `<app>-<image tag>@<private IPv6>`, distribution over `inet6_tcp` | `<app>.internal` |
| Kubernetes | `<pod name>@<pod IP>`, from the downward API | the headless Service FQDN |
| elsewhere | `<release>@<hostname>`, or `RELEASE_NODE` as given | whatever you export |

`FLY_APP_NAME` and `POD_IP` are the switches; neither being set is the
single-node default, which is also supported.

What changes with more than one node: Phoenix PubSub fan-out (LiveView updates
follow the reader's node either way), Oban's leader election for the hourly
digest, and `Node.list/0`. What stays per node: reader rate-limit buckets, the
`Mirror.Counters` totals cache and the `Confluence.Traffic` tallies. Multi-node
deployments should therefore size `CM_READER_RATE_LIMIT_PER_MINUTE` per node,
not for the deployment.

## Continuous integration

`.github/workflows/ci.yml` runs three jobs on every push and pull request:

| Job | What it is |
| --- | --- |
| **Static analysis** | `mix lint`: `compile --warnings-as-errors`, `deps.unlock --check-unused`, `format --check-formatted`, `credo --strict`, `sobelow --config` |
| **Suite and complexity** | Postgres 17 service, `mix cover` (the suite with coverage), then `mix complexity` (CRAP per function, threshold 30) |
| **Image, scan, non-root** | `docker build` (amd64), Trivy (`CRITICAL,HIGH`, `ignore-unfixed`), `id -u` must be `10001`, then the amd64 + arm64 index is published |

On `main` and on `v*.*.*` tags the image is published to
`ghcr.io/d-led/confluence_phx_mirror` under the **branch or tag name**: `:main`
(and `:latest` as well, for deployments that prefer it) for the branch,
`:v1.2.3` for a release. There are no commit-hash tags — a tag that changes with
every push says nothing about where the image came from, and the image already
carries its commit in `build_info.json`. Whatever is scanned and started in CI
is the branch's own tag, so a later stage that pulls `:main` pulls the image
that was checked. The same two gates run locally as `mix lint` and
`scripts/quality.sh`.

`.github/dependabot.yml` opens weekly pull requests for Hex, npm,
GitHub Actions and the proxy's image. The mirror image's base versions are build
arguments, so they are bumped by hand — the four `ARG`s at the top of the
`Dockerfile`.
