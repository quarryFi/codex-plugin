#!/usr/bin/env bash
# quarryFi session tracker for OpenAI Codex
# Called by Codex on lifecycle events: SessionStart, TaskStarted, TaskComplete, Stop
#
# Reads config from ~/.quarryfi/config.json
# Sends heartbeats to POST /api/heartbeat
# All errors are silenced — tracking must never interrupt the user.

set -o pipefail

CONFIG_FILE="$HOME/.quarryfi/config.json"
SESSION_FILE="/tmp/quarryfi-codex-session-$$"

# ── Helpers ──────────────────────────────────────────────────────────────────

read_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    exit 0  # no config → nothing to do
  fi

  # Parse JSON without jq dependency (portable)
  QUARRYFI_API_KEY=$(grep -o '"api_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*:.*"\(.*\)"/\1/')
  QUARRYFI_API_URL=$(grep -o '"api_url"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*:.*"\(.*\)"/\1/')

  if [ -z "$QUARRYFI_API_KEY" ] || [ -z "$QUARRYFI_API_URL" ]; then
    exit 0
  fi
}

get_project_name() {
  basename "${CODEX_PROJECT_DIR:-${CODEX_CWD:-$(pwd)}}"
}

get_editor() {
  # Codex sets CODEX_CLIENT to identify CLI vs App
  case "${CODEX_CLIENT:-cli}" in
    app|desktop) echo "Codex App" ;;
    *)           echo "Codex CLI" ;;
  esac
}

get_branch() {
  git -C "${CODEX_PROJECT_DIR:-${CODEX_CWD:-$(pwd)}}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

get_language() {
  # Best-effort: look at recent files in the project
  local dir="${CODEX_PROJECT_DIR:-${CODEX_CWD:-$(pwd)}}"
  if [ -f "$dir/package.json" ]; then echo "javascript"
  elif [ -f "$dir/Cargo.toml" ]; then echo "rust"
  elif [ -f "$dir/go.mod" ]; then echo "go"
  elif [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ]; then echo "python"
  elif [ -f "$dir/Gemfile" ]; then echo "ruby"
  else echo ""
  fi
}

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

send_heartbeat() {
  local event="$1"
  local duration="${2:-0}"
  local now
  now=$(timestamp_utc)

  local session_id="${CODEX_SESSION_ID:-$(cat "$SESSION_FILE" 2>/dev/null || echo "")}"
  local project
  project=$(get_project_name)
  local editor
  editor=$(get_editor)
  local branch
  branch=$(get_branch)
  local language
  language=$(get_language)

  local payload
  payload=$(cat <<EOF
{
  "heartbeats": [
    {
      "source": "codex",
      "project_name": "${project}",
      "editor": "${editor}",
      "timestamp": "${now}",
      "session_id": "${session_id}",
      "event": "${event}",
      "duration_seconds": ${duration},
      "branch": "${branch}",
      "language": "${language}"
    }
  ]
}
EOF
)

  curl -s -o /dev/null -w "" \
    --max-time 5 \
    -X POST \
    -H "Authorization: Bearer ${QUARRYFI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${QUARRYFI_API_URL}/api/heartbeat" 2>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  read_config

  # Codex passes the event name as the first argument or via CODEX_HOOK_EVENT
  local event="${1:-${CODEX_HOOK_EVENT:-unknown}}"

  case "$event" in
    SessionStart|TaskStarted)
      # Record session start time
      echo "$(date +%s)" > "$SESSION_FILE.start"
      # Generate session ID if Codex doesn't provide one
      if [ -z "${CODEX_SESSION_ID:-}" ]; then
        echo "codex-$(date +%s)-$$" > "$SESSION_FILE"
      fi
      send_heartbeat "$event"
      ;;

    TaskComplete|Stop)
      # Calculate duration from stored start time
      local duration=0
      if [ -f "$SESSION_FILE.start" ]; then
        local start_ts
        start_ts=$(cat "$SESSION_FILE.start")
        local now_ts
        now_ts=$(date +%s)
        duration=$(( now_ts - start_ts ))
        rm -f "$SESSION_FILE.start"
      fi
      send_heartbeat "$event" "$duration"
      # Clean up session file on stop
      if [ "$event" = "Stop" ]; then
        rm -f "$SESSION_FILE" "$SESSION_FILE.start"
      fi
      ;;

    *)
      # Unknown event — send a basic heartbeat anyway
      send_heartbeat "$event"
      ;;
  esac
}

# Run silently — never let tracking errors propagate to Codex
main "$@" 2>/dev/null
exit 0
