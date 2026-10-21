# build
FROM elixir:1.20-alpine AS builder

ARG APP_NAME=confluence_phx_mirror
ENV APP_NAME=${APP_NAME}
ARG MIX_ENV=prod
ENV MIX_ENV=${MIX_ENV}
ARG VERSION=unknown
ENV VERSION=${VERSION}

WORKDIR /app

RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache nodejs npm git build-base bash
RUN mix local.rebar --force && \
    mix local.hex --force

COPY mix.* ./
RUN mix deps.get --only ${MIX_ENV}

COPY . .
RUN ./scripts/mix_release.sh

# deployment
FROM alpine:3

ARG APP_NAME=confluence_phx_mirror
ENV APP_NAME=${APP_NAME}
ARG MIX_ENV=prod
ENV MIX_ENV=${MIX_ENV}

# UI ports
EXPOSE 4000
# EXPOSE 44000
# EPMD Port (needs to be defined as ERL_EPMD_PORT at run-time
# (if accessing from other machines is desired)
# EXPOSE 44369
# Distribution port
# EXPOSE 49000
# UDP Gossip Port
# EXPOSE 45892/udp

# install runtime dependencies
RUN apk --no-cache update && \
    apk --no-cache upgrade && \
    apk --no-cache add libcrypto3 libgcc libstdc++ ncurses-libs

WORKDIR /app

COPY --from=builder /app/_build/${MIX_ENV}/rel/${APP_NAME} .

RUN adduser -D app && \
    chown -R app: /app && \
    ls -rtl /app/bin

USER app

# ENTRYPOINT ["/app/bin/confluence_phx_mirror"]
# CMD ["start"]

# COPY priv/static/config/runtime_game_config.exs /app/config/

CMD ["sh", "-c", "/app/bin/confluence_phx_mirror eval ConfluencePhxMirror.Release.migrate && exec /app/bin/confluence_phx_mirror start"]
