#!/usr/bin/env bash
#
# update-fork.sh — sync this fork with upstream, rebuild, and redeploy 9router.
#
# Flow:
#   1. Verify clean working tree on the deploy branch.
#   2. Fetch upstream and bail early if already up to date.
#   3. Merge upstream. On merge CONFLICT → abort the merge (revert to the exact
#      previous commit) and report the error. Nothing is built, pushed, or restarted.
#   4. If package.json changed, reinstall deps.
#   5. Build the standalone bundle. On build failure → hard-reset to the previous
#      commit, rebuild the old version, restart, and exit non-zero.
#   6. Push the merge to origin, then restart the systemd service.
#   7. Health-check; if the service does not come up, roll everything back.
#
# Usage:
#   scripts/update-fork.sh            # full update + push + restart
#   scripts/update-fork.sh --no-push  # deploy locally without pushing to origin
#
set -euo pipefail

# ---- config -----------------------------------------------------------------
SERVICE="9router.service"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="master"
DEPLOY_BRANCH="master"
ORIGIN_REMOTE="origin"
PUSH=1

for arg in "$@"; do
  case "$arg" in
    --no-push) PUSH=0 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ---- helpers ----------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n'  "$*"; }
err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

# Move to repo root (this script lives in scripts/).
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

version() { grep -m1 '"version"' package.json | sed 's/.*"version": *"\([^"]*\)".*/\1/'; }

# ---- 1. preconditions -------------------------------------------------------
if [[ -n "$(git status --porcelain)" ]]; then
  err "Working tree is not clean. Commit or stash your changes first:"
  git status --short
  exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "$DEPLOY_BRANCH" ]]; then
  err "On branch '$current_branch', expected '$DEPLOY_BRANCH'. Switch first: git checkout $DEPLOY_BRANCH"
  exit 1
fi

PREV_HEAD="$(git rev-parse HEAD)"
PREV_VERSION="$(version)"
log "Current: v$PREV_VERSION ($PREV_HEAD)"

# ---- 2. fetch + check for updates -------------------------------------------
log "Fetching $UPSTREAM_REMOTE ..."
git fetch "$UPSTREAM_REMOTE" --tags

behind="$(git rev-list --count "HEAD..$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")"
if [[ "$behind" == "0" ]]; then
  ok "Already up to date with $UPSTREAM_REMOTE/$UPSTREAM_BRANCH. Nothing to do."
  exit 0
fi
log "$behind new commit(s) from $UPSTREAM_REMOTE/$UPSTREAM_BRANCH."

# ---- 3. merge (revert on conflict) ------------------------------------------
log "Merging $UPSTREAM_REMOTE/$UPSTREAM_BRANCH ..."
if ! git merge --no-edit "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
  err "Merge conflict — no changes applied. Reverting to previous state ($PREV_HEAD)."
  git merge --abort
  err "Conflicting files must be resolved by hand. To retry manually:"
  echo "    git merge $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  echo "    # resolve conflicts, then: git commit"
  exit 1
fi
ok "Merged cleanly → $(git rev-parse HEAD)"

# rollback helper for post-merge (pre-push) failures: restore old code and
# leave the service running the known-good previous build.
rollback_local() {
  err "Rolling back to previous version (v$PREV_VERSION)."
  git reset --hard "$PREV_HEAD"
  mise run build && sudo -n systemctl restart "$SERVICE" \
    && ok "Restored and restarted previous version." \
    || err "Automatic restore FAILED — inspect: systemctl status $SERVICE"
}

# ---- 4. deps (only if package.json changed) ---------------------------------
if ! git diff --quiet "$PREV_HEAD" HEAD -- package.json; then
  log "package.json changed — installing dependencies ..."
  if ! mise run setup; then
    err "Dependency install failed."
    rollback_local
    exit 1
  fi
fi

# ---- 5. build ---------------------------------------------------------------
log "Building production bundle (v$(version)) ..."
if ! mise run build; then
  err "Build failed."
  rollback_local
  exit 1
fi
ok "Build succeeded."

# ---- 6. push + restart ------------------------------------------------------
if [[ "$PUSH" == "1" ]]; then
  log "Pushing to $ORIGIN_REMOTE/$DEPLOY_BRANCH ..."
  git push "$ORIGIN_REMOTE" "$DEPLOY_BRANCH" || err "Push failed (continuing with local deploy)."
fi

log "Restarting $SERVICE ..."
if ! sudo -n systemctl restart "$SERVICE"; then
  err "Service restart failed. Check: systemctl status $SERVICE"
  exit 1
fi

# ---- 7. health check --------------------------------------------------------
sleep 5
if systemctl is-active --quiet "$SERVICE"; then
  ok "Service is active."
else
  err "Service did NOT come up after restart."
  rollback_local
  exit 1
fi

ok "Update complete — 9router now running v$(version) (was v$PREV_VERSION)."
