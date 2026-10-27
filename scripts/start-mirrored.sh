#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

CM_SOURCE=http CM_CONFLUENCE_SITE="$CM_CONFLUENCE_SITE" CM_ATL_EMAIL="$CM_ATL_EMAIL" CM_ATL_TOKEN="$CM_ATL_TOKEN" mix phx.server
