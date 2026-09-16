#!/usr/bin/env bash
#
# Container entrypoint for Render.
# Clones the repo (so accounts.txt can be committed back to GitHub), then runs the loop.
#
set -uo pipefail

WORK="/repo"
BRANCH="${GIT_BRANCH:-main}"

if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GIT_REPO_SLUG:-}" ]; then
  AUTH_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${GIT_REPO_SLUG}.git"

  echo "[entrypoint] Cloning ${GIT_REPO_SLUG} (branch ${BRANCH})..."
  rm -rf "$WORK"
  if git clone -q --branch "$BRANCH" "$AUTH_URL" "$WORK"; then
    echo "[entrypoint] Clone OK"
  else
    echo "[entrypoint] Clone failed; falling back to baked-in /app copy (no git push)."
    WORK="/app"
    export GIT_PUSH=0
  fi
else
  echo "[entrypoint] GITHUB_TOKEN/GIT_REPO_SLUG not set; running without git push."
  WORK="/app"
  export GIT_PUSH=0
fi

# Store accounts inside the repo checkout so they can be committed
export DATA_DIR="$WORK"
export REPO_DIR="$WORK"

echo "[entrypoint] WORK=$WORK GIT_PUSH=${GIT_PUSH:-0}"
cd "$WORK"
chmod +x ./register_verify.sh ./run_loop.sh 2>/dev/null || true

# On Render free tier this must be a WEB service, so serve HTTP on $PORT.
# server.py binds the port AND launches run_loop.sh in the background.
# If PORT isn't set (e.g. local/worker), just run the loop directly.
if [ -n "${PORT:-}" ]; then
  export REPO_DIR="$WORK"
  exec python3 ./server.py
else
  exec bash ./run_loop.sh
fi
