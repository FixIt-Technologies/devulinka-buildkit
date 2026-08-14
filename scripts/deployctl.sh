#!/usr/bin/env bash
# deployctl — buildkit v2 deploy client. Talks to the deploy-gateway on the
# Devulinka host; holds NO credentials (the gateway resolves this job's repo
# from its bastion-guest lease and enforces the target policy host-side).
#
# Usage:
#   deployctl <target> <verb> [args...] [@payload-file]
#
# A trailing @file streams that file as the payload: its byte count and
# sha256 are appended as the final two protocol args (the lovinka-ssh
# dispatcher framing) and the bytes ride the request body.
#
# Output: the dispatcher's combined output, live. Exit code: the remote
# verb's exit code.
set -euo pipefail

gateway=${DEPLOY_GATEWAY_URL:-http://192.168.251.1:8791}
sentinel='@@deploy-gateway-exit@@'

if (( $# < 2 )); then
  echo "usage: deployctl <target> <verb> [args...] [@payload-file]" >&2
  exit 2
fi

target=$1
verb=$2
shift 2

payload=''
args=()
for token in "$@"; do
  if [[ $token == @* ]]; then
    [[ -z $payload ]] || { echo "deployctl: only one @payload-file allowed" >&2; exit 2; }
    payload=${token#@}
  else
    args+=("$token")
  fi
done

[[ $target =~ ^[a-z][a-z0-9-]+$ ]] || { echo "deployctl: invalid target '$target'" >&2; exit 2; }
[[ $verb =~ ^[a-z][a-z0-9-]{0,31}$ ]] || { echo "deployctl: invalid verb '$verb'" >&2; exit 2; }

curl_args=(-sS -N -X POST)
if [[ -n $payload ]]; then
  [[ -f $payload && ! -L $payload ]] || {
    echo "deployctl: payload must be a regular, non-symlink file: $payload" >&2
    exit 2
  }
  bytes=$(wc -c < "$payload" | tr -d '[:space:]')
  if command -v sha256sum >/dev/null 2>&1; then
    sha256=$(sha256sum "$payload" | cut -d' ' -f1)
  else
    sha256=$(shasum -a 256 "$payload" | cut -d' ' -f1)
  fi
  args+=("$bytes" "$sha256")
  curl_args+=(--data-binary "@$payload" -H 'Content-Type: application/octet-stream')
fi

query=''
for arg in "${args[@]:-}"; do
  [[ -z $arg ]] && continue
  [[ $arg =~ ^[A-Za-z0-9._/@:=+-]{1,128}$ ]] || { echo "deployctl: invalid arg '$arg'" >&2; exit 2; }
  query+="${query:+&}arg=${arg}"
done

url="${gateway}/v1/deploy/${target}/${verb}${query:+?${query}}"
code_file=$(mktemp)
trap 'rm -f "$code_file"' EXIT

set +e
curl "${curl_args[@]}" "$url" | awk -v out="$code_file" -v sentinel="$sentinel" '
  $1 == sentinel && NF == 2 { code = $2; next }
  { print; fflush() }
  END { if (code == "") exit 3; print code > out }
'
pipe_status=("${PIPESTATUS[@]}")
set -e

if (( pipe_status[0] != 0 )); then
  echo "deployctl: gateway request failed (curl exit ${pipe_status[0]})" >&2
  exit 70
fi
if (( pipe_status[1] != 0 )); then
  echo "deployctl: gateway response ended without an exit status — deploy state UNKNOWN, do not retry blindly" >&2
  exit 70
fi
exit "$(cat "$code_file")"
