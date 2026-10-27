#!/usr/bin/env bash
#
# Ship a version to a Fly deployment that already exists.
#
#   scripts/fly-deploy.sh live                the mirror of a real Confluence site
#   scripts/fly-deploy.sh live --proxy        …and its front door, after it
#   scripts/fly-deploy.sh live --proxy-only   only its front door
#   scripts/fly-deploy.sh live --check        verify only: would this deploy?
#   scripts/fly-deploy.sh live --sync         …and enqueue a full snapshot afterwards
#   scripts/fly-deploy.sh demo                the demo mirror
#   scripts/fly-deploy.sh demo --proxy        …and the demo's front door
#
# A release ships the mirror and stops there, because the mirror is what a
# version changes. The oauth2-proxy in front of it has an image of its own and
# changes rarely: --proxy adds the front door to the same release, --proxy-only
# releases the front door alone, for when nothing else moved.
#
# No credentials and no DATABASE_URL: everything a release needs is already on
# the app, put there once by scripts/fly-provision.sh. This script creates
# nothing — no app, no database, no volume, no secret — and refuses before
# building anything if one of them is missing, naming the provisioning command
# that puts it there.
#
# Order matters. The proxy's upstream is the backend's Flycast address, so a
# proxy released first answers 502 until the backend exists: backend first.
#
# --sync is not part of a release. It enqueues a full snapshot on the running
# node afterwards, which is a data operation and usually done once, when a
# deployment has a database but no content.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib/fly.sh
. scripts/lib/fly.sh

usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
}

# --- live --------------------------------------------------------------------

deploy_live() {
  local provision="scripts/fly-provision.sh live"

  if deploys_backend; then
    require_secrets confluence-mirror-app "$provision" \
      DATABASE_URL SECRET_KEY_BASE RELEASE_COOKIE \
      CM_CONFLUENCE_SITE CM_ATL_EMAIL CM_ATL_TOKEN
    report_ready confluence-mirror-app
  else
    # Nothing of the mirror is built, but the proxy's upstream is this app.
    require_app confluence-mirror-app "$provision"
  fi

  if deploys_proxy; then
    require_secrets confluence-mirror "$provision" \
      OAUTH2_PROXY_CLIENT_ID OAUTH2_PROXY_CLIENT_SECRET OAUTH2_PROXY_COOKIE_SECRET
    report_ready confluence-mirror
  fi

  [ "$check" -eq 0 ] || return 0

  if deploys_backend; then
    release_backend confluence-mirror-app --flycast --no-public-ips
  fi

  if deploys_proxy; then
    release_proxy confluence-mirror deploy/fly/proxy
  fi
}

# --- demo --------------------------------------------------------------------

deploy_demo() {
  local provision="scripts/fly-provision.sh demo"

  if deploys_backend; then
    require_secrets confluence-mirror-demo-app "$provision" \
      DATABASE_URL SECRET_KEY_BASE RELEASE_COOKIE
    report_ready confluence-mirror-demo-app
  else
    # Nothing of the demo mirror is built, but the proxy's upstream is this app.
    require_app confluence-mirror-demo-app "$provision"
  fi

  if deploys_proxy; then
    require_secrets confluence-mirror-demo "$provision" \
      OAUTH2_PROXY_CLIENT_ID OAUTH2_PROXY_CLIENT_SECRET OAUTH2_PROXY_COOKIE_SECRET
    report_ready confluence-mirror-demo
  fi

  [ "$check" -eq 0 ] || return 0

  if deploys_backend; then
    release_backend confluence-mirror-demo-app . \
      --config deploy/fly/demo/fly.toml --flycast --no-public-ips
  fi

  if deploys_proxy; then
    release_proxy confluence-mirror-demo deploy/fly/proxy \
      --config deploy/fly/proxy/fly.demo.toml
  fi
}

# --- shared ------------------------------------------------------------------

# What this run ships. The mirror is the default because the mirror is what a
# version changes; the front door joins in only when asked.
deploys_backend() { [ "$proxy_only" -eq 0 ]; }

deploys_proxy() { [ "$with_proxy" -eq 1 ] || [ "$proxy_only" -eq 1 ]; }

report_ready() {
  local app
  for app in "$@"; do
    echo "deployable: $app is provisioned"
  done
}

# The mirror. `--flycast --no-public-ips` is the topology the proxy depends on:
# no public address, so the identity header cannot be forged by whoever finds
# the hostname. `--ha=false` because a Fly volume belongs to one Machine and
# the blob store is a filesystem. A directory argument is the build context;
# with none, the root `fly.toml` is the app.
release_backend() {
  local app=$1
  shift
  local version revision
  version=$(build_version)
  revision=$(build_revision)

  echo "deploying $app (version $version, commit $revision)"
  fly deploy "$@" --ha=false --app "$app" \
    --build-arg VERSION="$version" \
    --build-arg REVISION="$revision"
}

# Its front door, from the directory whose Dockerfile builds it. No build
# arguments: the proxy's image has no build info to record.
release_proxy() {
  local app=$1
  local dir=$2
  shift 2
  echo "deploying $app (the public front door)"
  fly deploy "$dir" "$@" --ha=false --app "$app"
}

seed_snapshot() {
  # Oban lives in the running node, so `eval` (a second, bare node) cannot
  # queue a job; `rpc` talks to the node that has the queue.
  local expression='Oban.insert(ConfluencePhxMirror.Sync.SnapshotWorker.new(JSON.decode!(~s|{"mode":"snapshot","trigger":"scripts/fly-deploy.sh"}|)))'

  echo "enqueueing a full snapshot"
  fly ssh console --app confluence-mirror-app \
    --command "/app/bin/confluence_phx_mirror rpc '$expression'" > /dev/null
  echo "  watch it: fly logs --app confluence-mirror-app | grep -i sync"
}

# --- dispatch ----------------------------------------------------------------

target=""
check=0
seed=0
with_proxy=0
proxy_only=0

for arg in "$@"; do
  case "$arg" in
    live | demo) target=$arg ;;
    --check) check=1 ;;
    --sync) seed=1 ;;
    --proxy) with_proxy=1 ;;
    --proxy-only) proxy_only=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $arg (--help for the accepted ones)"
      ;;
  esac
done

if [ -z "$target" ]; then
  usage >&2
  exit 64
fi

if [ "$with_proxy" -eq 1 ] && [ "$proxy_only" -eq 1 ]; then
  die "--proxy and --proxy-only ask for different releases; give one"
fi

if [ "$seed" -eq 1 ] && [ "$target" != live ]; then
  die "--sync needs the live target; the demo seeds itself from the bundled snapshot"
fi

case "$target" in
  live) deploy_live ;;
  demo) deploy_demo ;;
esac

if [ "$seed" -eq 1 ] && [ "$check" -eq 0 ]; then
  seed_snapshot
fi
