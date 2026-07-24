#!/usr/bin/env bash
# devulinka-buildkit project onboarding generator.
#
# Usage:
#   blueprint/new-project.sh <owner>/<repo> <shortname> [--go] [--priority]
#
#   <shortname>   used for the runner label (<shortname>-ci), container name,
#                 and workdir. Keep it short and kebab-case, e.g. "voke".
#   --go          also emit a go-test job (Go + Bun repo).
#   --priority    builds use the priority lane (deploy-critical projects only).
#
# Prints three blocks to stdout:
#   1. runner service      → paste into lovinka-devops-infra/apps/gh-runner/docker-compose.yml
#   2. .github/workflows/ci.yml starter
#   3. remaining manual steps
set -euo pipefail

[[ $# -ge 2 ]] || { sed -n '2,15p' "$0"; exit 2; }
SLUG="$1"; NAME="$2"; shift 2
OWNER="${SLUG%%/*}"
GO=0; PRIO=false
for a in "$@"; do
  case "$a" in
    --go) GO=1 ;;
    --priority) PRIO=true ;;
  esac
done

cat <<EOF
# ─── 1. runner service — append to lovinka-devops-infra/apps/gh-runner/docker-compose.yml
#        (inside services:, above the volumes: key), then ./scripts/deploy-gh-runner.sh

  # ${SLUG} CI lane (onboarded via devulinka-buildkit blueprint).
  runner-${NAME}:
    <<: *runner-base
    container_name: gh-runner-${NAME}
    # Size tier (Blacksmith-style, lean 1:2 ladder): new projects start on the
    # smallest tier — bump to devulinka-{4,8,16}vcpu-ubuntu-2604 (cpu_shares
    # N*1024, mem_limit N*2g) only when the lane demonstrably needs it.
    cpu_shares: 2048
    mem_limit: 4g
    environment:
      RUNNER_NAME: devops-vps-${NAME}-1
      RUNNER_WORKDIR: /opt/apps/gh-runner/work/${NAME}-1
      LABELS: self-hosted,linux,x64,${NAME}-ci,devops-vps,devulinka-2vcpu-ubuntu-2604
      REPO_URL: https://github.com/${SLUG}
      # GitHub App auth — no PAT. Requires the devulinka-runners app to be
      # installed on this repo (see step 3).
      APP_ID: \${GH_APP_ID}
      APP_LOGIN: ${OWNER}
      APP_PRIVATE_KEY: \${GH_APP_PRIVATE_KEY}
      DISABLE_AUTOMATIC_DEREGISTRATION: 'false'
      RUNNER_SCOPE: repo

# ─── 2. .github/workflows/ci.yml starter for ${SLUG}

name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
EOF

if [[ $GO -eq 1 ]]; then
cat <<EOF
  go-test:
    runs-on: [self-hosted, ${NAME}-ci]
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
      - run: go test ./...

EOF
fi

cat <<EOF
  test:
    uses: FixIt-Technologies/devulinka-buildkit/.github/workflows/test-bun.yml@v1
    with:
      runs-on: '["self-hosted","${NAME}-ci"]'
      bun-version: '1.3.9'
      run: |
        bun run test
        bun run build

  build-and-push:
    needs: [test]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    permissions:
      contents: read
      packages: write
    uses: FixIt-Technologies/devulinka-buildkit/.github/workflows/build-image.yml@v1
    with:
      runs-on: '["self-hosted","${NAME}-ci"]'
      image: ghcr.io/$(echo "$SLUG" | tr '[:upper:]' '[:lower:]')
      dockerfile: Dockerfile
      priority: ${PRIO}

# ─── 3. manual steps
#  a. Install the devulinka-runners GitHub App on ${SLUG}:
#     https://github.com/apps/devulinka-runners/installations/new
#     (owner ${OWNER}; for a NEW owner this is the only "credential" step ever)
#  b. Append block 1 to the gh-runner compose, commit, ./scripts/deploy-gh-runner.sh
#  c. Drop block 2 into ${SLUG}/.github/workflows/ci.yml, adjust test/build cmds
#  d. Verify: https://github.com/${SLUG}/settings/actions/runners shows the runner
EOF
