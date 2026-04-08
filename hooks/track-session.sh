#!/usr/bin/env bash
# quarryFi session tracker for OpenAI Codex
# Called by Codex on lifecycle events: SessionStart, TaskStarted, TaskComplete, Stop
#
# Supports multi-profile config with project-to-key routing.
# Reads profiles from ~/.quarryfi/config.json
# Sends heartbeats to POST /api/heartbeat for each matching profile.
# Appends each heartbeat to ~/.quarryfi/audit.log (capped at 1MB).
# All errors are silenced — tracking must never interrupt the user.

set -o pipefail

CONFIG_FILE="$HOME/.quarryfi/config.json"
AUDIT_LOG="$HOME/.quarryfi/audit.log"
AUDIT_MAX_BYTES=1048576  # 1MB
SESSION_FILE="/tmp/quarryfi-codex-session-$$"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Portable JSON string extraction (no jq dependency).
# Usage: json_string "$json" "field_name"
json_string() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

# Extract the "profiles" array entries as individual JSON objects.
# Each object is delimited by { … } inside the array.
# Usage: extract_profiles < config.json
extract_profiles() {
  awk '
    BEGIN { depth=0; capture=0; buf="" }
    /"profiles"/ { capture=1 }
    capture && /{/ {
      depth++
      if (depth >= 1) buf=""
    }
    capture && depth >= 1 { buf = buf $0 "\n" }
    capture && /}/ {
      depth--
      if (depth == 0) { print buf; buf="" }
    }
  '
}

# Extract the "projects" array values from a profile JSON block.
# Returns one path per line.
extract_projects() {
  printf '%s' "$1" | grep -o '"projects"[[:space:]]*:[[:space:]]*\[[^]]*\]' | \
    grep -o '"[^"]*"' | sed 's/"//g' | grep -v '^projects$'
}

# Check if cwd matches any project prefix in a profile.
# Returns 0 (match) or 1 (no match).
# If the profile has no "projects" key, it matches everything (legacy compat).
cwd_matches_profile() {
  local profile_block="$1"
  local cwd="$2"

  local projects
  projects=$(extract_projects "$profile_block")

  # No projects list → matches all (legacy single-key or catch-all profile)
  if [ -z "$projects" ]; then
    return 0
  fi

  while IFS= read -r prefix; do
    [ -z "$prefix" ] && continue
    case "$cwd" in
      "${prefix}"*) return 0 ;;
    esac
  done <<< "$projects"

  return 1
}

# Detect legacy single-key config format and normalize to a profile block.
is_legacy_config() {
  grep -q '"profiles"' "$CONFIG_FILE" 2>/dev/null && return 1
  grep -q '"api_key"' "$CONFIG_FILE" 2>/dev/null && return 0
  return 1
}

get_cwd() {
  echo "${CODEX_PROJECT_DIR:-${CODEX_CWD:-$(pwd)}}"
}

get_project_name() {
  basename "$(get_cwd)"
}

get_editor() {
  case "${CODEX_CLIENT:-cli}" in
    app|desktop) echo "Codex App" ;;
    *)           echo "Codex CLI" ;;
  esac
}

get_branch() {
  git -C "$(get_cwd)" rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

get_language() {
  local dir
  dir=$(get_cwd)
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

# ── Audit log ────────────────────────────────────────────────────────────────

rotate_audit_log() {
  if [ -f "$AUDIT_LOG" ]; then
    local size
    size=$(wc -c < "$AUDIT_LOG" 2>/dev/null || echo 0)
    if [ "$size" -gt "$AUDIT_MAX_BYTES" ]; then
      # Keep the last ~half of the file
      local lines
      lines=$(wc -l < "$AUDIT_LOG" 2>/dev/null || echo 0)
      local keep=$(( lines / 2 ))
      tail -n "$keep" "$AUDIT_LOG" > "$AUDIT_LOG.tmp" 2>/dev/null && \
        mv -f "$AUDIT_LOG.tmp" "$AUDIT_LOG" 2>/dev/null || \
        rm -f "$AUDIT_LOG.tmp"
    fi
  fi
}

append_audit() {
  local profile_name="$1"
  local payload="$2"
  local api_url="$3"
  local http_status="$4"

  # Single-line JSON record
  local record
  record=$(printf '{"ts":"%s","profile":"%s","api_url":"%s","http_status":"%s","payload":%s}' \
    "$(timestamp_utc)" "$profile_name" "$api_url" "$http_status" "$payload")

  rotate_audit_log
  echo "$record" >> "$AUDIT_LOG" 2>/dev/null || true
}

# ── Heartbeat ────────────────────────────────────────────────────────────────

build_payload() {
  local event="$1"
  local duration="$2"
  local now="$3"
  local session_id="$4"

  cat <<EOF
{"heartbeats":[{"source":"codex","project_name":"$(get_project_name)","editor":"$(get_editor)","timestamp":"${now}","session_id":"${session_id}","event":"${event}","duration_seconds":${duration},"branch":"$(get_branch)","language":"$(get_language)"}]}
EOF
}

send_heartbeat_to_profile() {
  local api_key="$1"
  local api_url="$2"
  local profile_name="$3"
  local payload="$4"

  local http_status
  http_status=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 \
    -X POST \
    -H "Authorization: Bearer ${api_key}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${api_url}/api/heartbeat" 2>/dev/null || echo "000")

  append_audit "$profile_name" "$payload" "$api_url" "$http_status"
}

# ── Profile dispatch ─────────────────────────────────────────────────────────

dispatch_to_profiles() {
  local event="$1"
  local duration="$2"

  local now
  now=$(timestamp_utc)
  local session_id="${CODEX_SESSION_ID:-$(cat "$SESSION_FILE" 2>/dev/null || echo "")}"
  local cwd
  cwd=$(get_cwd)
  local payload
  payload=$(build_payload "$event" "$duration" "$now" "$session_id")

  if is_legacy_config; then
    # Legacy single-key format: treat as one catch-all profile
    local api_key api_url
    api_key=$(json_string "$(cat "$CONFIG_FILE")" "api_key")
    api_url=$(json_string "$(cat "$CONFIG_FILE")" "api_url")
    if [ -n "$api_key" ] && [ -n "$api_url" ]; then
      send_heartbeat_to_profile "$api_key" "$api_url" "default" "$payload"
    fi
    return
  fi

  # Multi-profile format: iterate profiles, send to each that matches cwd
  local config_content
  config_content=$(cat "$CONFIG_FILE")

  # Extract each profile block and check for cwd match
  local profile_blocks
  profile_blocks=$(echo "$config_content" | extract_profiles)

  local sent=0
  while IFS= read -r block; do
    [ -z "$block" ] && continue

    if cwd_matches_profile "$block" "$cwd"; then
      local api_key api_url profile_name
      api_key=$(json_string "$block" "api_key")
      api_url=$(json_string "$block" "api_url")
      profile_name=$(json_string "$block" "name")
      profile_name="${profile_name:-unnamed}"

      if [ -n "$api_key" ] && [ -n "$api_url" ]; then
        send_heartbeat_to_profile "$api_key" "$api_url" "$profile_name" "$payload" &
        sent=$((sent + 1))
      fi
    fi
  done <<< "$profile_blocks"

  # Wait for background curl processes
  if [ "$sent" -gt 0 ]; then
    wait 2>/dev/null || true
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  if [ ! -f "$CONFIG_FILE" ]; then
    exit 0
  fi

  local event="${1:-${CODEX_HOOK_EVENT:-unknown}}"

  case "$event" in
    SessionStart|TaskStarted)
      echo "$(date +%s)" > "$SESSION_FILE.start"
      if [ -z "${CODEX_SESSION_ID:-}" ]; then
        echo "codex-$(date +%s)-$$" > "$SESSION_FILE"
      fi
      dispatch_to_profiles "$event" 0
      ;;

    TaskComplete|Stop)
      local duration=0
      if [ -f "$SESSION_FILE.start" ]; then
        local start_ts
        start_ts=$(cat "$SESSION_FILE.start")
        local now_ts
        now_ts=$(date +%s)
        duration=$(( now_ts - start_ts ))
        rm -f "$SESSION_FILE.start"
      fi
      dispatch_to_profiles "$event" "$duration"
      if [ "$event" = "Stop" ]; then
        rm -f "$SESSION_FILE" "$SESSION_FILE.start"
      fi
      ;;

    *)
      dispatch_to_profiles "$event" 0
      ;;
  esac
}

# Run silently — never let tracking errors propagate to Codex
main "$@" 2>/dev/null
exit 0
