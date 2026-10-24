#!/usr/bin/env bash
#
# The primitives `scripts/fly-provision.sh` and `scripts/fly-deploy.sh` agree
# on. Sourced, never executed.
#
# The two scripts ask different questions — "does this deployment exist?" and
# "ship the next version" — so this file holds only what both of them need to
# ask Fly: is the app there, is this secret there, is the volume there. Every
# function here either answers or creates; nothing modifies, because changing a
# live deployment is a decision (and belongs in a command a person typed).

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '  %s\n' "$*"
}

warning() {
  printf 'warning: %s\n' "$*" >&2
}

fly_require_cli() {
  command -v fly > /dev/null ||
    die "the fly CLI is not installed — https://fly.io/docs/flyctl/install/"
  fly auth whoami > /dev/null 2>&1 ||
    die "not logged in to Fly — run: fly auth login"
}

# flyctl's tables are laid out for people (the name column moves between
# commands and a staged secret is printed as "*NAME"), so read its JSON
# instead: `names apps list`, `names secrets list -a APP`, …
names() {
  local json
  json=$(fly "$@" --json) || die "fly $* failed"
  printf '%s' "$json" | python3 -c '
import json, sys
for item in json.load(sys.stdin):
    print(item.get("name") or item.get("Name"))
'
}

app_exists() {
  names apps list | grep -qx "$1"
}

has_secret() {
  names secrets list -a "$1" | grep -qx "$2"
}

# Everything a release needs must already be on the app. A missing one is not
# something a deploy can improvise: say which, and which command puts it there.
require_app() {
  local app=$1 provision=$2
  app_exists "$app" || die "app $app does not exist — run: $provision"
}

require_secrets() {
  local app=$1 provision=$2
  shift 2
  require_app "$app" "$provision"
  local missing="" name
  for name in "$@"; do
    has_secret "$app" "$name" || missing="$missing $name"
  done
  [ -z "$missing" ] || die "app $app is missing secrets:$missing — run: $provision"
}

ensure_app() {
  local app=$1
  if app_exists "$app"; then
    note "app $app: found"
    return
  fi
  fly apps create "$app" --org personal --yes > /dev/null
  note "app $app: created"
}

# A secret is written once. Rewriting one is a different act: rotating
# SECRET_KEY_BASE signs every reader out, rotating RELEASE_COOKIE makes the
# Machines strangers to each other, and a new Confluence token is somebody's
# decision — so a re-run reports "found" and leaves the value alone.
ensure_secret() {
  local app=$1 name=$2 value=$3
  if has_secret "$app" "$name"; then
    note "secret $name on $app: found (left as it is)"
    return
  fi
  # import reads stdin: a token must not appear in the process list.
  printf '%s=%s\n' "$name" "$value" | fly secrets import --app "$app" > /dev/null
  note "secret $name on $app: set"
}

ensure_secret_if_given() {
  local app=$1 name=$2 value=${3:-}
  if [ -n "$value" ]; then
    ensure_secret "$app" "$name" "$value"
  fi
}

ensure_volume() {
  local app=$1 name=$2 region=$3 size_gb=$4
  if names volumes list -a "$app" | grep -qx "$name"; then
    note "volume $name on $app: found (never resized)"
    return
  fi
  fly volumes create "$name" --app "$app" --region "$region" --size "$size_gb" --yes > /dev/null
  note "volume $name on $app: created ($region, ${size_gb} GB)"
}

# 48 bytes: SECRET_KEY_BASE and RELEASE_COOKIE only have to be unguessable.
random_hex() {
  openssl rand -hex 48
}

# oauth2-proxy base64-url-decodes this and accepts exactly 16, 24 or 32 bytes;
# standard base64 (with + and /) is rejected and then used as a raw string.
urlsafe_cookie_secret() {
  python3 -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
}

# oauth2-proxy cannot sign anyone in without GitHub's OAuth app, and the app
# deploys without it — so report what remains instead of half-failing.
report_missing_oauth() {
  local app=$1 missing="" name
  for name in OAUTH2_PROXY_CLIENT_ID OAUTH2_PROXY_CLIENT_SECRET; do
    has_secret "$app" "$name" || missing="$missing $name"
  done
  if [ -z "$missing" ]; then
    return 0
  fi
  warning "$app has no$missing — sign-in will fail until:"
  printf '         fly secrets set -a %s OAUTH2_PROXY_CLIENT_ID=… OAUTH2_PROXY_CLIENT_SECRET=…\n' \
    "$app" >&2
}

# The image records the build it is and the admin footer shows it, so a release
# carries the commit it was cut from — `-dirty` because an uncommitted tree is
# not the commit, and a footer that says otherwise is a lie about what is
# running.
build_version() {
  sed -n 's/^ *version: "\(.*\)",$/\1/p' mix.exs | head -1
}

build_revision() {
  local revision
  revision=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
  if ! git diff --quiet 2>/dev/null; then
    revision="$revision-dirty"
  fi
  printf '%s\n' "$revision"
}
