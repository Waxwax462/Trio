#!/usr/bin/env bash
# ci-validate.sh — Trigger and monitor GitHub Actions build_trio.yml
# Usage:
#   ci-validate.sh trigger [branch]   — fire workflow_dispatch, save run ID
#   ci-validate.sh check              — check saved run status, exit 0=pass 1=fail 2=still running
#   ci-validate.sh wait [timeout_s]   — block until complete, then exit 0=pass 1=fail
#   ci-validate.sh auto               — trigger if recent Trio commit exists (used by Stop hook)

set -euo pipefail

REPO="Waxwax462/Trio"
WORKFLOW="build_trio.yml"
TRIO_DIR="${CLAUDE_PROJECT_DIR:-.}/Trio"
STATE_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude-flow/ci-run-id"
DEFAULT_TIMEOUT=900  # 15 minutes

log() { echo "[CI] $*" >&2; }

# ── trigger ──────────────────────────────────────────────────────────────────
cmd_trigger() {
  local branch="${1:-main}"

  if ! command -v gh &>/dev/null; then
    log "gh CLI not found — skipping CI trigger"
    exit 0
  fi

  log "Triggering $WORKFLOW on $REPO ($branch)..."
  gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$branch" 2>&1 || {
    log "workflow_dispatch failed (check gh auth and repo permissions)"
    exit 1
  }

  # Give GitHub a moment to register the run
  sleep 6

  local run_id
  run_id=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 \
    --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")

  if [ -z "$run_id" ]; then
    log "Could not retrieve run ID"
    exit 1
  fi

  mkdir -p "$(dirname "$STATE_FILE")"
  echo "$run_id" > "$STATE_FILE"

  log "Run #$run_id started"
  log "View: https://github.com/$REPO/actions/runs/$run_id"
  echo "https://github.com/$REPO/actions/runs/$run_id"
}

# ── check ─────────────────────────────────────────────────────────────────────
cmd_check() {
  if [ ! -f "$STATE_FILE" ]; then
    log "No saved run ID found. Run 'ci-validate.sh trigger' first."
    exit 2
  fi

  local run_id
  run_id=$(cat "$STATE_FILE")

  local status conclusion
  status=$(gh run view "$run_id" --repo "$REPO" --json status --jq '.status' 2>/dev/null || echo "unknown")
  conclusion=$(gh run view "$run_id" --repo "$REPO" --json conclusion --jq '.conclusion' 2>/dev/null || echo "")

  case "$status" in
    completed)
      if [ "$conclusion" = "success" ]; then
        log "✅ Run #$run_id passed"
        exit 0
      else
        log "❌ Run #$run_id failed (conclusion: $conclusion)"
        log "Fetching failure output..."
        gh run view "$run_id" --repo "$REPO" --log-failed 2>/dev/null \
          | grep -A 30 "error\|FAILED\|Error\|Build FAILED" \
          | head -60 \
          || true
        exit 1
      fi
      ;;
    in_progress|queued|waiting|requested|pending)
      log "⏳ Run #$run_id is still $status"
      log "View: https://github.com/$REPO/actions/runs/$run_id"
      exit 2
      ;;
    *)
      log "Unknown status: $status"
      exit 2
      ;;
  esac
}

# ── wait ──────────────────────────────────────────────────────────────────────
cmd_wait() {
  local timeout="${1:-$DEFAULT_TIMEOUT}"
  local elapsed=0
  local poll=30

  if [ ! -f "$STATE_FILE" ]; then
    log "No saved run ID. Run 'ci-validate.sh trigger' first."
    exit 1
  fi

  local run_id
  run_id=$(cat "$STATE_FILE")
  log "Watching run #$run_id (timeout: ${timeout}s)..."

  while [ "$elapsed" -lt "$timeout" ]; do
    cmd_check 2>&1 && exit 0 || {
      local code=$?
      [ "$code" -eq 2 ] || exit "$code"   # 2 = still running, anything else = done
    }
    sleep "$poll"
    elapsed=$((elapsed + poll))
    log "${elapsed}s elapsed..."
  done

  log "Timeout after ${timeout}s — run may still be in progress"
  exit 1
}

# ── auto (called by Stop hook) ────────────────────────────────────────────────
cmd_auto() {
  # Only trigger if Trio has a commit within the last 15 minutes
  if [ ! -d "$TRIO_DIR/.git" ]; then
    exit 0
  fi

  local recent
  recent=$(git -C "$TRIO_DIR" log --since="15 minutes ago" --oneline HEAD 2>/dev/null | head -1)

  if [ -z "$recent" ]; then
    exit 0  # No recent commit — skip
  fi

  log "Recent Trio commit detected — triggering CI..."
  cmd_trigger "main"
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "${1:-auto}" in
  trigger) cmd_trigger "${2:-main}" ;;
  check)   cmd_check ;;
  wait)    cmd_wait "${2:-$DEFAULT_TIMEOUT}" ;;
  auto)    cmd_auto ;;
  *)       echo "Usage: ci-validate.sh [trigger|check|wait|auto]" >&2; exit 1 ;;
esac
