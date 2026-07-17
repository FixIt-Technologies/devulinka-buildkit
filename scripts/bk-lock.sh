#!/usr/bin/env bash
# devulinka-buildkit build-slot semaphore.
#
# Two slot classes on the Devulinka host:
#
# build (heavy image builds): 4 general (g1-g4) + 1 priority-reserved (p3).
#   normal builds   → compete for g1-g4 only
#   priority builds → may take g1-g4, and fall back to p3 (so a priority
#                     build — FixIt/deployik deploys — is never behind more
#                     than one running build)
#
# small (cheap CI checks — typecheck, lint, quick bun tests): 4 slots
# (s1-s4), fully separate from the build class so a light check never
# queues behind image builds and a burst of light checks cannot swamp
# the box either. --priority is ignored for this class.
#
# Locks are plain flock(2) files under $BK_LOCK_DIR. Runner containers all
# bind-mount the host's /var/lock, so the same inode is contended across every
# repo's runners — this is what gives a GLOBAL cap that GitHub (repos across
# 4 owners) cannot provide.
#
# The lock fd is held by THIS process for the exact duration of the wrapped
# command and released on exit (clean, killed, or OOM'd) — no stale-lock
# cleanup needed.
#
# Usage: bk-lock.sh [--priority] [--class build|small] [--timeout SECONDS] [--label TEXT] -- cmd args...
set -euo pipefail

LOCK_DIR="${BK_LOCK_DIR:-/var/lock/devulinka}"
TIMEOUT=2700
PRIORITY=0
CLASS="build"
LABEL="build"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --priority) PRIORITY=1; shift ;;
    --class)    CLASS="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --label)    LABEL="$2"; shift 2 ;;
    --)         shift; break ;;
    *) echo "bk-lock: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ $# -gt 0 ]] || { echo "bk-lock: no command given" >&2; exit 2; }
command -v flock >/dev/null || { echo "bk-lock: flock(1) not available — this must run on a Linux runner" >&2; exit 2; }

mkdir -p "$LOCK_DIR"

case "$CLASS" in
  build)
    SLOTS=(g1 g2 g3 g4)
    [[ $PRIORITY -eq 1 ]] && SLOTS=(g1 g2 g3 g4 p3)
    ;;
  small)
    SLOTS=(s1 s2 s3 s4)
    ;;
  *) echo "bk-lock: unknown --class $CLASS (build|small)" >&2; exit 2 ;;
esac

# Queue telemetry for runner-hub: JSONL events, best-effort (telemetry must
# never fail a build). O_APPEND writes of one short line are atomic.
EVENTS="$LOCK_DIR/events.jsonl"
emit() { # emit <event> <slot> <extra-json-fields>
  printf '{"ts":"%s","event":"%s","slot":"%s","label":"%s","priority":%s,"class":"%s","pid":%s%s}\n' \
    "$(date -u +%FT%TZ)" "$1" "$2" "$LABEL" "$PRIORITY" "$CLASS" "$$" "${3:-}" >> "$EVENTS" 2>/dev/null || true
}

start=$SECONDS
next_report=0
waiting_emitted=0
while (( SECONDS - start < TIMEOUT )); do
  for slot in "${SLOTS[@]}"; do
    lockfile="$LOCK_DIR/build-$slot.lock"
    exec {fd}>>"$lockfile"
    if flock -n "$fd"; then
      waited=$(( SECONDS - start ))
      echo "bk-lock: acquired slot $slot after ${waited}s (label=$LABEL priority=$PRIORITY)"
      emit acquire "$slot" ",\"wait_s\":$waited"
      # Run the command as a child (it inherits the lock fd) so we can emit a
      # release event with duration + exit code. If this wrapper is killed,
      # the trap forwards the signal; the kernel drops the lock when the last
      # holder of the fd exits either way — no stale locks.
      "$@" &
      child=$!
      trap 'kill "$child" 2>/dev/null' TERM INT
      set +e; wait "$child"; rc=$?; set -e
      emit release "$slot" ",\"wait_s\":$waited,\"held_s\":$(( SECONDS - start - waited )),\"rc\":$rc"
      exit "$rc"
    fi
    exec {fd}>&-
  done
  if (( waiting_emitted == 0 )); then
    emit wait "-" ""
    waiting_emitted=1
  fi
  if (( SECONDS - start >= next_report )); then
    echo "bk-lock: waiting for a slot (${SLOTS[*]}) — $(( SECONDS - start ))s elapsed, timeout ${TIMEOUT}s"
    next_report=$(( SECONDS - start + 30 ))
  fi
  sleep 5
done

echo "bk-lock: timed out after ${TIMEOUT}s waiting for a build slot" >&2
emit timeout "-" ""
exit 75
