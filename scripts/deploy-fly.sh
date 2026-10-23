#!/usr/bin/env bash
#
# Deploy the mirror and its oauth2-proxy front door to Fly.io — in that order,
# because the proxy's upstream is the backend's Flycast address, and a proxy
# deployed first would answer 502 until the backend exists.
#
#   ./scripts/deploy-fly.sh
#
# Two apps, one public IP:
#
#   confluence-mirror-demo       oauth2-proxy, public, GitHub OAuth
#   confluence-mirror-demo-app   the mirror, Flycast only, no public IP
#
# What you have to provide beforehand:
#
#   DATABASE_URL                      postgres://user:pass@host:5432/db
#   OAUTH2_PROXY_CLIENT_ID            GitHub OAuth app client id
#   OAUTH2_PROXY_CLIENT_SECRET        …and its secret
#   OAUTH2_PROXY_EMAIL_DOMAINS        optional, defaults to "*"
#   CM_ADMINS                         optional, comma-separated administrator e-mails
#
# The GitHub OAuth app's callback URL is
# https://confluence-mirror-demo.fly.dev/oauth2/callback
#
# Everything else (SECRET_KEY_BASE, RELEASE_COOKIE, the proxy's cookie secret)
# is generated once, on the first run, and left alone afterwards: rotating the
# cookie secret signs every reader out, and rotating RELEASE_COOKIE splits the
# cluster. Both are secrets, so nothing here writes them to disk.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BACKEND_APP="confluence-mirror-demo-app"
PROXY_APP="confluence-mirror-demo"
REGION="ams"
VOLUME="mirror_blobs"

if ! command -v fly > /dev/null; then
  echo "error: the fly CLI is not installed — https://fly.io/docs/flyctl/install/" >&2
  exit 1
fi
if ! fly auth whoami > /dev/null 2>&1; then
  echo "error: not logged in to Fly — run: fly auth login" >&2
  exit 1
fi

if [ -z "${DATABASE_URL:-}" ]; then
  echo "error: DATABASE_URL is not set (postgres://user:pass@host:5432/db)" >&2
  exit 1
fi

# --- apps --------------------------------------------------------------------

ensure_app() {
  local app=$1
  if ! fly apps list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "$app"; then
    echo "creating app: $app"
    fly apps create "$app" --org personal --yes
  fi
}

ensure_secret() {
  local app=$1 name=$2 value=$3
  if ! secret_names "$app" | grep -qx "$name"; then
    fly secrets set --app "$app" "$name=$value" > /dev/null
    echo "set $name on $app"
  fi
}

secret_names() {
  fly secrets list --app "$1" 2>/dev/null | awk 'NR > 1 { print $1 }'
}

random_secret() {
  # 48 bytes: SECRET_KEY_BASE and RELEASE_COOKIE only have to be unguessable.
  python3 -c 'import secrets; print(secrets.token_urlsafe(48))'
}

urlsafe_cookie_secret() {
  # oauth2-proxy base64-url-decodes this and accepts exactly 16, 24 or 32
  # bytes. Standard base64 (+ and /) is rejected and then used as a raw string,
  # so generate URL-safe base64 of 32 bytes.
  python3 -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
}

ensure_app "$BACKEND_APP"
ensure_app "$PROXY_APP"

# --- backend secrets ---------------------------------------------------------

ensure_secret "$BACKEND_APP" SECRET_KEY_BASE "$(random_secret)"
ensure_secret "$BACKEND_APP" DATABASE_URL "$DATABASE_URL"
# The cookie every node must share to form a cluster; regenerating it later
# makes the Machines strangers to each other until they restart together.
ensure_secret "$BACKEND_APP" RELEASE_COOKIE "$(random_secret)"

if [ -n "${CM_ADMINS:-}" ]; then
  ensure_secret "$BACKEND_APP" CM_ADMINS "$CM_ADMINS"
fi

# --- the volume --------------------------------------------------------------
# Attachments live on a volume, one per Machine, in the region the Machine runs
# in. Re-running this is a no-op once the volume exists.

if ! fly volumes list --app "$BACKEND_APP" 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -q .; then
  echo "creating volume: $VOLUME ($REGION, 1 GB)"
  fly volumes create "$VOLUME" --app "$BACKEND_APP" --region "$REGION" --size 1 --yes
fi

# --- backend -----------------------------------------------------------------
# --flycast gives the app a private address only; --no-public-ips makes sure it
# never gets one. --ha=false keeps it at one Machine, which is what a single
# volume supports.

echo "deploying backend: $BACKEND_APP"
fly deploy . \
  --app "$BACKEND_APP" \
  --flycast \
  --no-public-ips \
  --ha=false

# --- proxy secrets -----------------------------------------------------------

if [ -z "${OAUTH2_PROXY_CLIENT_ID:-}" ] || [ -z "${OAUTH2_PROXY_CLIENT_SECRET:-}" ]; then
  echo "warning: OAUTH2_PROXY_CLIENT_ID / OAUTH2_PROXY_CLIENT_SECRET are not set." >&2
  echo "         The proxy will start, but sign-in will fail until they are:" >&2
  echo "         fly secrets set -a $PROXY_APP OAUTH2_PROXY_CLIENT_ID=... OAUTH2_PROXY_CLIENT_SECRET=..." >&2
else
  ensure_secret "$PROXY_APP" OAUTH2_PROXY_CLIENT_ID "$OAUTH2_PROXY_CLIENT_ID"
  ensure_secret "$PROXY_APP" OAUTH2_PROXY_CLIENT_SECRET "$OAUTH2_PROXY_CLIENT_SECRET"
fi

ensure_secret "$PROXY_APP" OAUTH2_PROXY_COOKIE_SECRET "$(urlsafe_cookie_secret)"

if [ -n "${OAUTH2_PROXY_EMAIL_DOMAINS:-}" ]; then
  ensure_secret "$PROXY_APP" OAUTH2_PROXY_EMAIL_DOMAINS "$OAUTH2_PROXY_EMAIL_DOMAINS"
fi

# --- proxy -------------------------------------------------------------------

echo "deploying proxy: $PROXY_APP"
fly deploy deploy/fly/proxy --app "$PROXY_APP"

echo
echo "done. public URL: https://${PROXY_APP}.fly.dev/"
echo "sanity check:    curl -I https://${PROXY_APP}.fly.dev/   # 302 to GitHub"
