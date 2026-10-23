#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# https://hexdocs.pm/distillery/guides/phoenix_walkthrough.html
# https://hexdocs.pm/distillery/guides/upgrades_and_downgrades.html
# https://hexdocs.pm/distillery/guides/running_migrations.html
# + https://blog.appsignal.com/2018/10/16/elixir-alchemy-hot-code-reloading-in-elixir.html

export MIX_ENV=prod

# echo "--== Compile assets ==--"
cd assets
npm install
cd ..

echo "--== Phoenix setup ==--"
#mix setup
mix deps.get --only prod
mix compile

echo "--== Digest ==--"
mix phx.digest
mix assets.deploy

# echo "--== Removing the existing release directory ==--"
echo "--== Building the release ==--"

# What the admin footer reports: git describe and the short commit here, since
# there is a checkout; the Dockerfile passes the same values in as build
# arguments because a build context has no .git.
mix build.info

mix release --force --overwrite
