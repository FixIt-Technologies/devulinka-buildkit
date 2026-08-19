#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/deploy-gateway-curl.sh"
# shellcheck disable=SC2154
deploy_gateway_curl -fsS --max-time 10 "${deploy_gateway_url}/v1/whoami"
