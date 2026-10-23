# The public front door: oauth2-proxy holding the only public IP in front of
# the mirror.
#
# Verified against oauth2-proxy v7.15.5. The client id, client secret, cookie
# secret and (for GitHub organisations) the org/team settings are Fly secrets
# set by scripts/deploy-fly.sh — nothing secret belongs in this file.

# A tagged release, not `latest`: the image is reproduced by tag, and
# Dependabot (.github/dependabot.yml, docker/…) proposes the next one.
FROM quay.io/oauth2-proxy/oauth2-proxy:v7.15.5

# Settings come from the environment (the `[env]` block of `fly.toml` here,
# or `fly.demo.toml`, and Fly secrets); the
# image's own entrypoint starts the proxy. It already runs as an unprivileged
# user — CI asserts that for the mirror image, and `docker run --rm --entrypoint
# /usr/bin/id quay.io/oauth2-proxy/oauth2-proxy:v7.15.5` shows the uid here.
EXPOSE 4180
