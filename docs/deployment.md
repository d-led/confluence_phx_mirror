# Deploying the mirror

One shape, two platforms:

```mermaid
flowchart LR
  R[reader] -->|TLS| P[oauth2-proxy<br/>the only public address]
  P -->|X-Forwarded-Email<br/>X-Forwarded-Proto| M[the mirror<br/>no public address]
  M --> DB[(Postgres)]
  M --> V[blob volume]
```

The proxy answers "who is this?". The mirror never trusts a caller it could not
have reached any other way.

## Do this now

| | Fly.io | Kubernetes |
| --- | --- | --- |
| **1. create** everything that exists once | `./scripts/fly-provision.sh live` | `kubectl apply -f deploy/k8s/secret.yaml` (from `secret.example.yaml`) |
| **2. deploy** every version | `./scripts/fly-deploy.sh live --proxy` (the first time; after that `live` alone ships the mirror) | `kubectl apply -f deploy/k8s/confluence-mirror.yaml` then `-f deploy/k8s/oauth2-proxy.yaml` |
| **done when** | the proxy's URL answers and `/admin` shows your build | the Ingress answers and `/admin` shows your build |

Neither deploy script creates anything, and neither needs credentials:
`fly-provision.sh` is the one that reads them, once.

## What each platform provides

| | Fly.io | Kubernetes |
| --- | --- | --- |
| configuration | [`fly.toml`](../fly.toml) + [`deploy/fly/proxy`](../deploy/fly/proxy) | [`deploy/k8s`](../deploy/k8s) |
| front door | app `confluence-mirror` (oauth2-proxy, the only public IP) | `oauth2-proxy` Deployment + Ingress |
| the mirror | app `confluence-mirror-app`, Flycast only | `confluence-mirror` Deployment + ClusterIP Service |
| database | app `confluence-mirror-db` (Postgres 18, attached) | managed Postgres |
| migrations | `[deploy] release_command = "/app/bin/migrate"` | the `confluence-mirror-migrate` Job |
| attachments | Fly volume `mirror_blobs` | PVC `mirror-blobs` (`ReadWriteMany`) |
| clustering | `FLY_APP_NAME.internal` | headless Service via `DNS_CLUSTER_QUERY` |

## Which Fly file is which

One rule: **a directory you would deploy from holds one `fly.toml`, and that
file is the app that directory is about.** `fly deploy` reads the `fly.toml` of
the directory it is given, so the default is always the right app.

| file | app | what it is |
| --- | --- | --- |
| `fly.toml` | `confluence-mirror-app` | **the live mirror of a real site — this is the one that is deployed** |
| `deploy/fly/proxy/fly.toml` | `confluence-mirror` | its oauth2-proxy front door (public) |
| `deploy/fly/demo/fly.toml` | `confluence-mirror-demo-app` | the self-contained demo (`CM_SOURCE=demo`, no credentials) |
| `deploy/fly/proxy/fly.demo.toml` | `confluence-mirror-demo` | the demo's proxy |

The demo pair is the only thing that is not a default, and its file names say
`demo`:

```bash
fly deploy --config deploy/fly/demo/fly.toml
fly deploy deploy/fly/proxy --config deploy/fly/proxy/fly.demo.toml
```

The two backends deploy from the repository root, because the Dockerfile needs
the whole project as its build context. The two proxies deploy from
`deploy/fly/proxy`, where their Dockerfile is.

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

### The image with the demo snapshot

No Confluence credentials and no proxy: the image can serve the bundled demo.
Four commands, about four minutes, most of it the build:

```bash
# 1. a database — any Postgres will do; this is the one CI runs the suite on
docker run -d --name mirror-db \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_USER=postgres \
  -p 55432:5432 postgres:17

export SECRET_KEY_BASE=$(openssl rand -hex 48)
export DATABASE_URL=ecto://postgres:postgres@host.docker.internal:55432/postgres

# 2. build, and migrate — the step a deploy runs, before any request is served
docker build -t confluence-mirror .
docker run --rm -e DATABASE_URL -e SECRET_KEY_BASE \
  confluence-mirror /app/bin/migrate

# 3. serve the demo, with no sign-in in the way
docker run -d --name mirror -p 4000:4000 \
  -e DATABASE_URL -e SECRET_KEY_BASE \
  -e CM_SOURCE=demo -e MIRROR_AUTO_ADMIN=true -e PHX_HOST=localhost \
  confluence-mirror

# 4. fill it — once, on the running node
docker exec mirror /app/bin/confluence_phx_mirror rpc \
  'ConfluencePhxMirror.Sync.run(:snapshot)'
```

**Done when** <http://localhost:4000> says `40 pages` in two spaces, and
`/api/v1/search?q=roadmap` finds the PROD roadmap.

The details that make this work, and that are easy to be surprised by:

* **A release has no seeds.** `mix setup` fills a *development* database by
  running `priv/repo/seeds.exs`; `/app/bin/migrate` only migrates. Without step
  4 the mirror is empty and says so — "no content has been copied from …", `0
  pages`, `[]` from the API. Step 4 is the same call the *Sync now* button on
  `/admin` makes, and it has to reach the running node, which is why it is
  `docker exec` and not a second `docker run`.
* **`MIRROR_AUTO_ADMIN=true` is allowed because the source is the demo.** A
  release pointed at a real site refuses it without
  `MIRROR_ALLOW_UNSAFE_IDENTITY=1`, which is the point of that guard.
* **`host.docker.internal` is Docker Desktop's name for your machine** (macOS and
  Windows). On Linux either add `--add-host=host.docker.internal:host-gateway`,
  or put the database and the mirror on one compose network and use its service
  name instead of a published port.
* **Keep `SECRET_KEY_BASE` fixed across restarts.** Sessions, magic links and
  MCP access tokens are signed with it; a new value signs everybody out.
* **The demo writes attachments to `/app/var/mirror`**, which is inside the
  container. Add `-v mirror-blobs:/app/var/mirror` to the run in step 3 if they
  should outlive `docker rm`.

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
./scripts/fly-deploy.sh live              # the mirror, and only the mirror
./scripts/fly-deploy.sh live --proxy      # the mirror, then its front door
./scripts/fly-deploy.sh live --proxy-only # just the front door
./scripts/fly-deploy.sh live --check      # verify only: would this deploy?
./scripts/fly-deploy.sh live --sync       # …and enqueue a full snapshot
```

It refuses before building anything if an app or a secret is missing, and
names the provisioning command that puts it there. A release ships the mirror
and stops there, because the mirror is what a version changes: the proxy's
image is its own and changes rarely. `--proxy` adds it to the same release,
`--proxy-only` releases it alone. When one run ships both, it still ships them
in the only order that works — the proxy's upstream is the mirror's Flycast
address, so a proxy released first answers 502.

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

## Releases and images

CI gates every push: static analysis, the suite with coverage and CRAP, and an
image build that is scanned and checked for a non-root uid. The jobs, their
timings and how to run them at home are in
[developers.md](developers.md#quality-gates).

What a *release* means here:

* **Tags follow the branch or tag name.** `ghcr.io/d-led/confluence_phx_mirror`
  is published as `:main` (and `:latest`) on every push to main, and as
  `:v1.2.3` for a release tag.
* **There are no commit-hash tags.** A tag that changes with every push says
  nothing about where the image came from, and the image already carries its
  commit in `build_info.json`.
* **A push publishes amd64 only.** The arm64 half is compiled under QEMU and is
  the expensive part (about 15 minutes), so it is built on a release tag or on
  request.

Catching an image breakage before a tag costs two minutes at home:

```bash
docker build .                                   # does it build at all
scripts/quality.sh --image                       # builds it, checks uid 10001
git tag v1.2.3 && git push origin v1.2.3         # a release, amd64 + arm64
gh workflow run ci --ref main --field image=true # …or ask for a fresh index
```

One consequence worth knowing before pulling `:latest` on an arm64 host: that
image is amd64 only until somebody dispatches the index, so the host runs it
emulated. Release tags always carry both.

`.github/dependabot.yml` opens weekly pull requests for Hex, npm, GitHub Actions
and the proxy's image. The mirror image's base versions are build arguments, so
they are bumped by hand — the four `ARG`s at the top of the `Dockerfile`.
