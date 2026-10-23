#!/usr/bin/env bash
#
# Deploy the main site — the mirror of a real Confluence site — to Fly.io.
#
#   CM_CONFLUENCE_SITE=https://acme.atlassian.net \
#   CM_ATL_EMAIL=me@acme.com \
#   CM_ATL_TOKEN=… \
#   CM_ADMINS=me@acme.com \
#   ./scripts/deploy-fly-main.sh
#
#   ./scripts/deploy-fly-main.sh --sync    …and enqueue the first full snapshot
#
# One app, no public IP:
#
#   confluence-mirror-app   the mirror, Flycast only (fly.toml)
#   confluence-mirror-db    its Postgres, same region, attached
#
# The oauth2-proxy front door is a separate step (deploy/fly/proxy, app
# `confluence-mirror`); until it exists nothing on the internet can reach this
# app, because `--no-public-ips` leaves it a private address only. `fly proxy
# 8080:8080 -a confluence-mirror-app` is how a laptop looks at it.
#
# What the script creates once and never again: the app, the Postgres cluster,
# its attachment, the blob volume, and the generated SECRET_KEY_BASE /
# RELEASE_COOKIE. Re-running it is just a deploy — which is the point.
#
# Secrets it does not manage: the Confluence credentials come from the
# environment on the first run and are then stored on the app. Change them with
# `fly secrets set -a confluence-mirror-app CM_ATL_TOKEN=…`.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP="confluence-mirror-app"
DB_APP="confluence-mirror-db"
REGION="ams"
VOLUME="mirror_blobs"
CONFIG="fly.toml"
RELEASE="confluence_phx_mirror"

seed=0
for arg in "$@"; do
  case "$arg" in
    --sync) seed=1 ;;
    -h | --help)
      sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown option: $arg (try --help)" >&2
      exit 64
      ;;
  esac
done

# --- preflight ---------------------------------------------------------------

if ! command -v fly > /dev/null; then
  echo "error: the fly CLI is not installed — https://fly.io/docs/flyctl/install/" >&2
  exit 1
fi
if ! fly auth whoami > /dev/null 2>&1; then
  echo "error: not logged in to Fly — run: fly auth login" >&2
  exit 1
fi
if [ ! -f "$CONFIG" ]; then
  echo "error: $CONFIG is missing; run this from a checkout of the repository" >&2
  exit 1
fi

for name in CM_CONFLUENCE_SITE CM_ATL_EMAIL CM_ATL_TOKEN; do
  if [ -z "${!name:-}" ]; then
    echo "error: $name is not set — the mirror needs the site and an API token" >&2
    exit 1
  fi
done

# --- helpers -----------------------------------------------------------------

secret_names() {
  # A staged secret is printed with a leading "*", so the name is not $1 there.
  fly secrets list --app "$1" 2>/dev/null | tr -d '*' | awk 'NR > 1 { print $1 }'
}

ensure_app() {
  if ! fly apps list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "$APP"; then
    echo "creating app: $APP"
    fly apps create "$APP" --org personal --yes
  fi
}

ensure_secret() {
  local name=$1 value=$2
  # Already set means already chosen: rotating SECRET_KEY_BASE invalidates every
  # session, and rotating RELEASE_COOKIE breaks the cluster's handshake.
  if ! secret_names "$APP" | grep -qx "$name"; then
    printf '%s=%s\n' "$name" "$value" | fly secrets import --app "$APP" > /dev/null
    echo "set $name on $APP"
  fi
}

random_secret() {
  # 48 bytes: SECRET_KEY_BASE and RELEASE_COOKIE only have to be unguessable.
  openssl rand -hex 48
}

ensure_database() {
  if ! fly apps list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "$DB_APP"; then
    echo "creating postgres: $DB_APP ($REGION)"
    echo "  unmanaged Postgres: no support contract, and you own the backups."
    echo "  Volume snapshots are on; WAL backups need \`--enable-backups\`,"
    echo "  which accepts Tigris's terms of service — a decision for a human."
    # The smallest volume postgres will take. It holds the mirror's content and
    # nothing else — blobs live on the attachment volume — and a volume cannot
    # be shrunk later, so start where you mean to be.
    fly postgres create \
      --name "$DB_APP" \
      --org personal \
      --region "$REGION" \
      --initial-cluster-size 1 \
      --vm-size shared-cpu-1x \
      --vm-memory 1024 \
      --volume-size 1
  fi

  # Attaching creates a scoped role and the DATABASE_URL secret; doing it twice
  # would fail, and the secret being present is the proof it already happened.
  if ! secret_names "$APP" | grep -qx DATABASE_URL; then
    echo "attaching postgres: $DB_APP"
    fly postgres attach "$DB_APP" --app "$APP"
  fi
}

ensure_volume() {
  if ! fly volumes list --app "$APP" 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -q .; then
    echo "creating volume: $VOLUME ($REGION, 10 GB)"
    fly volumes create "$VOLUME" --app "$APP" --region "$REGION" --size 10 --yes
  fi
}

seed_snapshot() {
  # Oban lives in the running node, so `eval` (a second, bare node) cannot queue
  # a job; `rpc` talks to the node that has the queue.
  local expression='Oban.insert(ConfluencePhxMirror.Sync.SnapshotWorker.new(JSON.decode!(~s|{"mode":"snapshot","trigger":"the deploy script"}|)))'

  echo "enqueueing the first snapshot"
  fly ssh console --app "$APP" --command "/app/bin/$RELEASE rpc '$expression'" > /dev/null
  echo "  watch it: fly logs --app $APP | grep -i sync"
}

# --- do it -------------------------------------------------------------------

ensure_app
ensure_database
ensure_volume

ensure_secret SECRET_KEY_BASE "$(random_secret)"
ensure_secret RELEASE_COOKIE "$(random_secret)"
ensure_secret CM_SOURCE http
ensure_secret CM_CONFLUENCE_SITE "$CM_CONFLUENCE_SITE"
ensure_secret CM_ATL_EMAIL "$CM_ATL_EMAIL"
ensure_secret CM_ATL_TOKEN "$CM_ATL_TOKEN"

# The administrator list names real people, so it is a secret and never a line
# in a committed file: export CM_ADMINS=… before the first run.
if [ -n "${CM_ADMINS:-}" ]; then
  ensure_secret CM_ADMINS "$CM_ADMINS"
fi

# The admin footer names the build it is showing, so the commit goes into the
# image rather than being guessed afterwards.
version=$(sed -n 's/^ *version: "\(.*\)",$/\1/p' mix.exs | head -1)
revision=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
git diff --quiet 2>/dev/null || revision="$revision-dirty"

echo "deploying $APP (version $version, commit $revision)"
# No --config: this file is the root `fly.toml`, which is what `fly deploy`
# reads anyway. $CONFIG exists only so the check above can name the file.
fly deploy \
  --ha=false \
  --flycast \
  --no-public-ips \
  --build-arg VERSION="$version" \
  --build-arg REVISION="$revision"

if [ "$seed" -eq 1 ]; then
  seed_snapshot
fi

echo
echo "done. $APP has a private address only:"
echo "  fly status --app $APP"
echo "  fly proxy 8080:8080 --app $APP      # then http://localhost:8080/health"
echo "  curl -H 'X-Forwarded-Proto: https' http://localhost:8080/health"
echo
echo "next: the oauth2-proxy front door (deploy/fly/proxy, app confluence-mirror),"
echo "then CM_PROXY_AUTH=true CM_TRUST_PROXY_HEADERS=true and"
echo "MIRROR_ALLOW_UNSAFE_IDENTITY=1 on $APP."
