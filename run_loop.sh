#!/usr/bin/env bash
#
# Runs register_verify.sh in a loop, creating one account per iteration
# with a buffer (delay) between accounts.
#
# Usage:
#   ./run_loop.sh                 # default: infinite, ~90-150s between accounts
#   ./run_loop.sh 300             # fixed base delay of 300s between accounts
#   ./run_loop.sh 300 50          # base 300s + up to 50s random jitter
#   MAX=10 ./run_loop.sh 120      # stop after 10 successful accounts
#
# Env vars:
#   MAX   -> stop after this many iterations (default: 0 = run forever)
#
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/register_verify.sh"

# Config via args OR env vars (env vars are convenient on Render).
BASE_DELAY="${1:-${BASE_DELAY:-90}}"   # base seconds to wait between accounts
JITTER="${2:-${JITTER:-60}}"           # additional random seconds (0..JITTER)
MAX="${MAX:-0}"                        # 0 = infinite

log() { printf '\033[1;33m[loop %s] %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"; }

count=0
success=0
fail=0

log "Starting loop. base_delay=${BASE_DELAY}s jitter=0-${JITTER}s max=${MAX:-inf}"

while :; do
  count=$((count + 1))
  log "=== Account attempt #$count ==="

  if "$SCRIPT"; then
    success=$((success + 1))
    log "attempt #$count OK  (success=$success fail=$fail)"
  else
    fail=$((fail + 1))
    log "attempt #$count FAILED (success=$success fail=$fail)"
  fi

  # Stop if we hit the cap
  if [ "$MAX" -gt 0 ] && [ "$success" -ge "$MAX" ]; then
    log "Reached MAX=$MAX successful accounts. Stopping."
    break
  fi

  # Buffer time before the next account
  WAIT=$(( BASE_DELAY + (RANDOM % (JITTER + 1)) ))
  log "Waiting ${WAIT}s before next account..."
  sleep "$WAIT"
done

log "Done. total=$count success=$success fail=$fail"
