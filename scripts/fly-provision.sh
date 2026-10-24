#!/usr/bin/env bash
#
# Make a Fly deployment exist. Nothing here ships code.
#
#   scripts/fly-provision.sh live      the mirror of a real Confluence site
#   scripts/fly-provision.sh demo      the self-contained demo pair
#
# Both targets are two apps — a private mirror and its public oauth2-proxy —
# because the identity header the mirror trusts is only believable while the
# proxy is the only way in (docs/deployment.md).
#
# This is the once-per-deployment half: the apps, the Postgres cluster (`live`)
# or the DATABASE_URL you bring (`demo`), the blob volume, and the secrets an
# app cannot boot without. Re-running it is safe — every step finds what exists
# and says so — but it changes nothing: a secret is written once, because
# rotating SECRET_KEY_BASE signs every reader out, rotating RELEASE_COOKIE
# makes the Machines strangers to each other, and a new Confluence token is
# somebody's decision. `fly secrets set` is how those are made.
#
# Shipping a version is the other script, and it needs no credentials:
#
#   scripts/fly-deploy.sh live
#
# Read from the environment:
#
#   live   CM_CONFLUENCE_SITE, CM_ATL_EMAIL, CM_ATL_TOKEN   required
#          CM_ADMINS                                       optional
#   demo   DATABASE_URL                                     required
#   both   OAUTH2_PROXY_CLIENT_ID, OAUTH2_PROXY_CLIENT_SECRET   optional
#          OAUTH2_PROXY_EMAIL_DOMAINS                          optional
#
# The GitHub OAuth app's callback URL:
#
#   live   https://confluence-mirror.fly.dev/oauth2/callback
#   demo   https://confluence-mirror-demo.fly.dev/oauth2/callback

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib/fly.sh
. scripts/lib/fly.sh

REGION="ams"

usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
}

# --- live: a real Confluence site --------------------------------------------

provision_live() {
  local app=confluence-mirror-app
  local proxy=confluence-mirror
  local db=confluence-mirror-db

  local name
  for name in CM_CONFLUENCE_SITE CM_ATL_EMAIL CM_ATL_TOKEN; do
    [ -n "${!name:-}" ] ||
      die "$name is not set — the live mirror needs the site and an API token:
       CM_CONFLUENCE_SITE=https://acme.atlassian.net CM_ATL_EMAIL=me@acme.com CM_ATL_TOKEN=…"
  done

  echo "provisioning $app (the mirror of a real site)"
  ensure_app "$app"
  ensure_postgres "$db" "$app"
  ensure_volume "$app" mirror_blobs "$REGION" 10

  ensure_secret "$app" SECRET_KEY_BASE "$(random_hex)"
  ensure_secret "$app" RELEASE_COOKIE "$(random_hex)"
  ensure_secret "$app" CM_CONFLUENCE_SITE "$CM_CONFLUENCE_SITE"
  ensure_secret "$app" CM_ATL_EMAIL "$CM_ATL_EMAIL"
  ensure_secret "$app" CM_ATL_TOKEN "$CM_ATL_TOKEN"
  ensure_secret_if_given "$app" CM_ADMINS "${CM_ADMINS:-}"

  echo "provisioning $proxy (its public front door)"
  provision_proxy "$proxy"

  echo
  echo "next: scripts/fly-deploy.sh live"
  echo "      (the front door has no public address until that deploy: fly ips list -a $proxy)"
}

# A Fly Postgres cluster, attached. Unmanaged: no support contract, and the
# backups are the operator's — see docs/operations.md before trusting it.
ensure_postgres() {
  local db=$1 app=$2
  if app_exists "$db"; then
    note "postgres $db: found"
  else
    note "postgres $db: creating ($REGION, 1 GB — a volume cannot be shrunk)"
    note "  unmanaged Postgres: no support contract, and you own the backups."
    note "  Volume snapshots are on; WAL backups need --enable-backups, which"
    note "  accepts Tigris's terms of service — a decision for a human."
    fly postgres create \
      --name "$db" \
      --org personal \
      --region "$REGION" \
      --initial-cluster-size 1 \
      --vm-size shared-cpu-1x \
      --vm-memory 1024 \
      --volume-size 1 > /dev/null
  fi

  # Attaching creates a scoped role and the DATABASE_URL secret; a second
  # attempt fails, and the secret being there is the proof it already happened.
  if has_secret "$app" DATABASE_URL; then
    note "role and DATABASE_URL on $app: found"
  else
    note "attaching $db to $app"
    fly postgres attach "$db" --app "$app"
  fi
}

# --- demo: the bundled snapshot, no Confluence credentials -------------------

provision_demo() {
  local app=confluence-mirror-demo-app
  local proxy=confluence-mirror-demo

  [ -n "${DATABASE_URL:-}" ] ||
    die "DATABASE_URL is not set — the demo brings its own Postgres
       (postgres://user:pass@host:5432/db), and the release migrates it on deploy"

  echo "provisioning $app (the bundled demo snapshot)"
  ensure_app "$app"
  ensure_volume "$app" mirror_blobs "$REGION" 1

  ensure_secret "$app" SECRET_KEY_BASE "$(random_hex)"
  ensure_secret "$app" RELEASE_COOKIE "$(random_hex)"
  ensure_secret "$app" DATABASE_URL "$DATABASE_URL"

  echo "provisioning $proxy (its public front door)"
  provision_proxy "$proxy"

  echo
  echo "next: scripts/fly-deploy.sh demo"
}

# --- both: the proxy app, and the sign-in it cannot work without -------------

provision_proxy() {
  local proxy=$1
  ensure_app "$proxy"
  ensure_secret "$proxy" OAUTH2_PROXY_COOKIE_SECRET "$(urlsafe_cookie_secret)"
  ensure_secret_if_given "$proxy" OAUTH2_PROXY_CLIENT_ID "${OAUTH2_PROXY_CLIENT_ID:-}"
  ensure_secret_if_given "$proxy" OAUTH2_PROXY_CLIENT_SECRET "${OAUTH2_PROXY_CLIENT_SECRET:-}"
  ensure_secret_if_given "$proxy" OAUTH2_PROXY_EMAIL_DOMAINS "${OAUTH2_PROXY_EMAIL_DOMAINS:-}"
  report_missing_oauth "$proxy"
}

# --- dispatch ----------------------------------------------------------------

case "${1:-}" in
  live) provision_live ;;
  demo) provision_demo ;;
  -h | --help) usage ;;
  '')
    usage >&2
    exit 64
    ;;
  *)
    die "unknown target: $1 (want: live or demo; --help for more)"
    ;;
esac
