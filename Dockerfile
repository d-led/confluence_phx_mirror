# syntax=docker/dockerfile:1
#
# The mirror as one OTP release, built once and shipped as an image:
#
#   docker build -t confluence-mirror \
#     --build-arg VERSION="$(git describe --tags --always)" .
#
#   docker run --rm -e DATABASE_URL=... -e SECRET_KEY_BASE=... confluence-mirror \
#     /app/bin/migrate            # once per deploy, before instances start
#   docker run -p 4000:4000 -e ... confluence-mirror
#                                # /app/bin/server, PHX_SERVER=true
#
# Three stages, because each needs a different toolchain and only the last one
# ships: Node installs the browser dependencies, the Elixir image compiles the
# release, and a Debian runtime carries the release plus the shared libraries
# BEAM needs — no compiler, no Node, no git, no Hex cache in the result.
#
# Base images are pinned to dated tags rather than to `latest`, so a rebuild of
# an old commit builds the same toolchain. Dependabot (.github/dependabot.yml)
# opens a pull request when a newer one appears, and CI scans the result.
#
# Debian rather than Alpine for the runtime: the mirror talks to Confluence over
# TLS and to Postgres by name, and glibc's resolver behaves like the one every
# library was tested against. Trixie (Debian 13, current stable) rather than
# bookworm: the same image scans with one CRITICAL and 59 HIGH findings on
# bookworm and none of either on trixie, all of them unfixed either way.

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=trixie-20261020-slim
ARG NODE_VERSION=24.22.1-trixie-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# --- browser dependencies ----------------------------------------------------
# `assets.deploy` bundles assets/js/app.js with esbuild, which reads its
# packages from assets/node_modules. Node is only needed to install them, and
# the nodes are copied from here into the build (see below) rather than added
# to the Elixir image: a builder does not decide which Node is current.
FROM docker.io/node:${NODE_VERSION} AS assets

WORKDIR /assets
COPY assets/package.json assets/package-lock.json ./
RUN npm ci --no-audit --no-fund

# --- the release -------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

# build-essential for NIFs, git for the two GitHub dependencies (heroicons and
# daisyUI), unzip for the esbuild and tailwind binaries fetched by `mix
# assets.setup`.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       build-essential git ca-certificates unzip \
  && rm -rf /var/lib/apt/lists/*

# Node and npm from the stage above — the same distribution family (trixie),
# so the binaries link against the libc that is here. `mix assets.deploy` calls
# `npm ci` itself; with node_modules already in place it only verifies them.
# The npm and npx entry points are symlinks in the Node image, so they are
# recreated here rather than copied as files.
COPY --from=assets /usr/local/bin/node /usr/local/bin/node
COPY --from=assets /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

WORKDIR /app

# What the admin footer reports about this build. The values are build
# arguments rather than runtime environment, because a release should know what
# it was built from even when it starts somewhere that sets nothing —
# `mix build.info` writes them into priv/, so they travel inside the image.
ARG VERSION=dev
ARG REVISION=
ARG CI_PROVIDER=
ARG CI_WORKFLOW=
ARG CI_RUN_NUMBER=
ARG CI_RUN_URL=
ENV BUILD_VERSION=${VERSION} \
    BUILD_REVISION=${REVISION} \
    BUILD_CI_PROVIDER=${CI_PROVIDER} \
    BUILD_CI_WORKFLOW=${CI_WORKFLOW} \
    BUILD_CI_RUN_NUMBER=${CI_RUN_NUMBER} \
    BUILD_CI_RUN_URL=${CI_RUN_URL}

RUN mix local.hex --force \
  && mix local.rebar --force

# Dependencies first: a source change does not re-resolve or re-fetch them.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Compile-time configuration decides how dependencies are compiled, so it has
# to be in place before deps.compile. runtime.exs deliberately is not copied
# yet: it is read when the release boots, not when it is built.
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY rel rel
COPY assets assets
COPY --from=assets /assets/node_modules assets/node_modules

# `assets.setup` fetches the esbuild and tailwind standalone binaries into
# _build, so the image bundles with the same versions a developer has locally.
RUN mix assets.setup \
  && mix compile \
  && mix assets.deploy

COPY config/runtime.exs config/
RUN mix build.info \
  && mix release

# --- what ships --------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runtime

ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="Confluence Mirror" \
      org.opencontainers.image.description="A read-only, searchable mirror of a Confluence site" \
      org.opencontainers.image.source="https://github.com/d-led/confluence_phx_mirror" \
      org.opencontainers.image.licenses="MPL-2.0" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# Runtime libraries the release needs: openssl for crypto, libstdc++ for NIFs,
# ncurses for the shell, libsctp for distribution, locales so UTF-8 titles sort
# and log correctly, tzdata for the digest hour and "recent" timestamps.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates libstdc++6 openssl libncurses6 libsctp1 locales tzdata \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod

# A fixed, unprivileged uid/gid: Kubernetes' runAsNonRoot and a volume's fsGroup
# need a number, and "app" then means the same thing in every deployment.
RUN groupadd --system --gid 10001 app \
  && useradd --system --uid 10001 --gid app --home-dir /app --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder --chown=10001:10001 /app/_build/prod/rel/confluence_phx_mirror ./

# Attachments live in a path-based blob store, outside the release. /app/var is
# the one directory the app writes to; mount a volume there (a Fly volume, a
# Kubernetes PVC) to keep the bytes across restarts.
RUN mkdir -p /app/var/mirror \
  && chown -R 10001:10001 /app/var
ENV MIRROR_BLOB_ROOT=/app/var/mirror

USER 10001:10001

EXPOSE 4000

CMD ["/app/bin/server"]
