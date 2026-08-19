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
# verb's exit code. The status line is authenticated with a per-request
# nonce (X-Exit-Nonce), so dispatcher output cannot forge it.
#
# Exit 70 = the response ended without the gateway's status line: the deploy
# state is UNKNOWN. Never retry an unknown-state step blindly (a migrate may
# have half-run) — inspect the target first.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/deploy-gateway-curl.sh"
# shellcheck disable=SC2154
gateway=$deploy_gateway_url
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

# Percent-encode one arg for the query string. The server-side charset
# excludes true metacharacters, but `+` and friends have QUERY semantics —
# an unencoded `+` arrives as a space. Encode everything non-unreserved.
urlencode() {
  local s=$1 out='' c i
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9.~_-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

query=''
for arg in ${args[@]+"${args[@]}"}; do
  [[ -z $arg ]] && continue
  [[ $arg =~ ^[A-Za-z0-9._/@:=+-]{1,128}$ ]] || { echo "deployctl: invalid arg '$arg'" >&2; exit 2; }
  query+="${query:+&}arg=$(urlencode "$arg")"
done

# Per-request nonce: the gateway echoes it on the status line, so a line the
# DISPATCHER prints can never be mistaken for the gateway's verdict.
nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
curl_args+=(-H "X-Exit-Nonce: $nonce")

url="${gateway}/v1/deploy/${target}/${verb}${query:+?${query}}"
code_file=$(mktemp)
trap 'rm -f "$code_file"' EXIT

set +e
deploy_gateway_curl "${curl_args[@]}" "$url" | awk -v out="$code_file" -v sentinel="$sentinel" -v nonce="$nonce" '
  # Every nonce-bearing status line is consumed (never leaked as output);
  # only a numeric 0-255 code counts as a verdict — anything else leaves
  # code empty and the client exits 70 (unknown state).
  $1 == sentinel && $2 == nonce {
    if (NF == 3 && $3 ~ /^[0-9]+$/ && $3 + 0 <= 255) code = $3
    next
  }
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
  echo "deployctl: gateway response ended without an authenticated exit status — deploy state UNKNOWN, do not retry blindly" >&2
  exit 70
fi
exit "$(cat "$code_file")"
