#!/usr/bin/env bash
# quarryFi session tracker for OpenAI Codex
#
# Accuracy-first design:
# - Event hooks still flush immediately on real Codex activity
# - A background timer sends active-session heartbeats every 60s
# - All senders share one "last sent" clock to avoid double-counting
# - Failures are silenced so tracking never interrupts Codex

set -o pipefail

CONFIG_DIR="$HOME/.quarryfi"
CONFIG_FILE="$CONFIG_DIR/config.json"
AUDIT_LOG="$CONFIG_DIR/audit.log"
AUDIT_MAX_BYTES=1048576
DEFAULT_API_URL="https://quarryfi.smashedstudiosllc.workers.dev"
HEARTBEAT_INTERVAL_SECONDS=60
MIN_TICK_DURATION_SECONDS=45

CLI_EVENT="${1:-}"
CLI_CWD="${2:-}"
CLI_SESSION_ID="${3:-}"
EVENT_JSON=$(cat 2>/dev/null || true)

json_string() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

EVENT_NAME_FROM_JSON=$(json_string "$EVENT_JSON" "hook_event_name")
EVENT_CWD_FROM_JSON=$(json_string "$EVENT_JSON" "cwd")
EVENT_SESSION_ID_FROM_JSON=$(json_string "$EVENT_JSON" "session_id")
EVENT_FILE_PATH_FROM_JSON=$(json_string "$EVENT_JSON" "file_path")

get_cwd() {
  if [ -n "$CLI_CWD" ]; then
    echo "$CLI_CWD"
    return
  fi
  if [ -n "$EVENT_CWD_FROM_JSON" ]; then
    echo "$EVENT_CWD_FROM_JSON"
    return
  fi
  echo "${CODEX_PROJECT_DIR:-${CODEX_CWD:-$(pwd)}}"
}

session_dir() {
  local cwd="$1"
  local hash
  hash=$(printf '%s' "$cwd" | shasum -a 256 2>/dev/null | cut -c1-12)
  echo "$CONFIG_DIR/session-codex-${hash}"
}

session_file() {
  local cwd="$1"
  local name="$2"
  echo "$(session_dir "$cwd")/$name"
}

ensure_session_dir() {
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  mkdir -p "$1" 2>/dev/null || true
}

get_session_id() {
  local cwd="$1"
  local sid_file
  sid_file=$(session_file "$cwd" "session_id")

  if [ -n "$CLI_SESSION_ID" ]; then
    printf '%s' "$CLI_SESSION_ID" > "$sid_file" 2>/dev/null || true
    echo "$CLI_SESSION_ID"
    return
  fi
  if [ -n "$EVENT_SESSION_ID_FROM_JSON" ]; then
    printf '%s' "$EVENT_SESSION_ID_FROM_JSON" > "$sid_file" 2>/dev/null || true
    echo "$EVENT_SESSION_ID_FROM_JSON"
    return
  fi
  if [ -n "${CODEX_SESSION_ID:-}" ]; then
    printf '%s' "$CODEX_SESSION_ID" > "$sid_file" 2>/dev/null || true
    echo "$CODEX_SESSION_ID"
    return
  fi
  if [ -f "$sid_file" ]; then
    cat "$sid_file" 2>/dev/null
    return
  fi

  local new_id
  new_id="codex-$(date +%s)-${RANDOM:-0}"
  printf '%s' "$new_id" > "$sid_file" 2>/dev/null || true
  echo "$new_id"
}

persist_session_context() {
  local cwd="$1"
  local session_id="$2"
  printf '%s' "$cwd" > "$(session_file "$cwd" "cwd")" 2>/dev/null || true
  printf '%s' "$session_id" > "$(session_file "$cwd" "session_id")" 2>/dev/null || true
}

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

epoch_now() {
  date +%s 2>/dev/null || echo 0
}

clamp_duration() {
  local duration="$1"
  if [ "$duration" -lt 0 ] 2>/dev/null; then
    echo 0
  elif [ "$duration" -gt 86400 ] 2>/dev/null; then
    echo 86400
  else
    echo "$duration"
  fi
}

duration_since_last_sent() {
  local cwd="$1"
  local now_ts="$2"
  local last_file
  last_file=$(session_file "$cwd" "last_sent")
  if [ ! -f "$last_file" ]; then
    echo 0
    return
  fi

  local last_ts
  last_ts=$(cat "$last_file" 2>/dev/null)
  if [ -z "$last_ts" ]; then
    echo 0
    return
  fi

  clamp_duration $(( now_ts - last_ts ))
}

record_last_sent() {
  local cwd="$1"
  local now_ts="$2"
  printf '%s' "$now_ts" > "$(session_file "$cwd" "last_sent")" 2>/dev/null || true
}

cleanup_session_state() {
  local cwd="$1"
  rm -f \
    "$(session_file "$cwd" "last_sent")" \
    "$(session_file "$cwd" "session_id")" \
    "$(session_file "$cwd" "cwd")" \
    "$(session_file "$cwd" "timer.pid")" 2>/dev/null || true
  rmdir "$(session_dir "$cwd")" 2>/dev/null || true
}

rotate_audit_log() {
  if [ -f "$AUDIT_LOG" ]; then
    local size
    size=$(wc -c < "$AUDIT_LOG" 2>/dev/null || echo 0)
    if [ "$size" -gt "$AUDIT_MAX_BYTES" ]; then
      local lines keep
      lines=$(wc -l < "$AUDIT_LOG" 2>/dev/null || echo 0)
      keep=$(( lines / 2 ))
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

  rotate_audit_log
  printf '{"ts":"%s","profile":"%s","api_url":"%s","http_status":"%s","payload":%s}\n' \
    "$(timestamp_utc)" "$profile_name" "$api_url" "$http_status" "$payload" >> "$AUDIT_LOG" 2>/dev/null || true
}

append_status_audit() {
  local project_name="$1"
  local event_name="$2"
  local status="$3"

  rotate_audit_log
  printf '{"ts":"%s","project":"%s","event":"%s","status":"%s"}\n' \
    "$(timestamp_utc)" "$project_name" "$event_name" "$status" >> "$AUDIT_LOG" 2>/dev/null || true
}

get_project_name() {
  local cwd="$1"
  local name
  name=$(basename "$cwd")
  if [ -z "$name" ] || [ "$name" = "/" ]; then
    name=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
  fi
  echo "${name:-unknown}"
}

get_editor() {
  case "${CODEX_CLIENT:-cli}" in
    app|desktop) echo "Codex App" ;;
    *) echo "Codex CLI" ;;
  esac
}

get_branch() {
  local cwd="$1"
  git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
}

get_language() {
  local dir="$1"

  if [ -n "$EVENT_FILE_PATH_FROM_JSON" ]; then
    local ext
    ext="${EVENT_FILE_PATH_FROM_JSON##*.}"
    if [ -n "$ext" ] && [ "$ext" != "$EVENT_FILE_PATH_FROM_JSON" ]; then
      case "$ext" in
        ts|tsx) echo "typescript"; return ;;
        js|jsx) echo "javascript"; return ;;
        py) echo "python"; return ;;
        rs) echo "rust"; return ;;
        go) echo "go"; return ;;
        rb) echo "ruby"; return ;;
        java|kt) echo "java"; return ;;
        php) echo "php"; return ;;
        swift) echo "swift"; return ;;
        c|cpp|h) echo "c/cpp"; return ;;
        sh|bash|zsh) echo "shell"; return ;;
        json) echo "json"; return ;;
        md|markdown) echo "markdown"; return ;;
      esac
    fi
  fi

  if [ -f "$dir/package.json" ] || [ -f "$dir/tsconfig.json" ]; then
    if [ -f "$dir/tsconfig.json" ]; then echo "typescript"; return; fi
    echo "javascript"; return
  fi
  if [ -f "$dir/Cargo.toml" ]; then echo "rust"; return; fi
  if [ -f "$dir/go.mod" ]; then echo "go"; return; fi
  if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ] || [ -f "$dir/setup.cfg" ]; then echo "python"; return; fi
  if [ -f "$dir/Gemfile" ]; then echo "ruby"; return; fi
  if [ -f "$dir/build.gradle" ] || [ -f "$dir/pom.xml" ]; then echo "java"; return; fi
  if [ -f "$dir/mix.exs" ]; then echo "elixir"; return; fi
  if [ -f "$dir/composer.json" ]; then echo "php"; return; fi
  if [ -f "$dir/Package.swift" ]; then echo "swift"; return; fi
  if [ -f "$dir/CMakeLists.txt" ] || [ -f "$dir/Makefile" ]; then echo "c/cpp"; return; fi

  echo "multi"
}

get_file_type() {
  local dir="$1"

  if [ -n "$EVENT_FILE_PATH_FROM_JSON" ]; then
    local event_ext
    event_ext="${EVENT_FILE_PATH_FROM_JSON##*.}"
    if [ -n "$event_ext" ] && [ "$event_ext" != "$EVENT_FILE_PATH_FROM_JSON" ]; then
      echo "$event_ext"
      return
    fi
  fi

  local recent_ext
  recent_ext=$(git -C "$dir" diff --name-only HEAD~3 HEAD 2>/dev/null | grep '\.' | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  if [ -n "$recent_ext" ]; then
    local ext_count
    ext_count=$(git -C "$dir" diff --name-only HEAD~3 HEAD 2>/dev/null | grep '\.' | sed 's/.*\.//' | sort -u | wc -l | tr -d ' ')
    if [ "$ext_count" -gt 3 ]; then
      echo "multi"
    else
      echo "$recent_ext"
    fi
    return
  fi

  case "$(get_language "$dir")" in
    typescript) echo "ts" ;;
    javascript) echo "js" ;;
    python) echo "py" ;;
    rust) echo "rs" ;;
    go) echo "go" ;;
    ruby) echo "rb" ;;
    java) echo "java" ;;
    php) echo "php" ;;
    swift) echo "swift" ;;
    c/cpp) echo "cpp" ;;
    shell) echo "sh" ;;
    *) echo "multi" ;;
  esac
}

map_event() {
  case "$1" in
    SessionStart) echo "session_start" ;;
    Stop) echo "session_end" ;;
    *) echo "heartbeat" ;;
  esac
}

build_payload() {
  local event="$1"
  local duration="$2"
  local now="$3"
  local session_id="$4"
  local project_name="$5"
  local editor="$6"
  local branch="$7"
  local language="$8"
  local file_type="$9"

  cat <<EOF
{"heartbeats":[{"source":"codex","project_name":"${project_name}","language":"${language}","file_type":"${file_type}","branch":"${branch}","editor":"${editor}","timestamp":"${now}","duration_seconds":${duration},"session_id":"${session_id}","event":"${event}"}]}
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

is_legacy_config() {
  grep -q '"profiles"' "$CONFIG_FILE" 2>/dev/null && return 1
  grep -q '"api_key"' "$CONFIG_FILE" 2>/dev/null && return 0
  return 1
}

dispatch_to_profiles() {
  local cwd="$1"
  local session_id="$2"
  local event="$3"
  local duration="$4"

  [ ! -f "$CONFIG_FILE" ] && return

  local now project_name editor branch language file_type payload
  now=$(timestamp_utc)
  project_name=$(get_project_name "$cwd")
  editor=$(get_editor)
  branch=$(get_branch "$cwd")
  language=$(get_language "$cwd")
  file_type=$(get_file_type "$cwd")
  payload=$(build_payload "$event" "$duration" "$now" "$session_id" "$project_name" "$editor" "$branch" "$language" "$file_type")

  if is_legacy_config; then
    local config_content api_key api_url
    config_content=$(cat "$CONFIG_FILE" 2>/dev/null)
    api_key=$(json_string "$config_content" "api_key")
    api_url=$(json_string "$config_content" "api_url")
    if [ -n "$api_key" ] && [ -n "$api_url" ]; then
      send_heartbeat_to_profile "$api_key" "$api_url" "default" "$payload"
    else
      append_status_audit "$project_name" "$event" "skipped:missing_credentials"
    fi
    return
  fi

  if command -v node >/dev/null 2>&1; then
    local matched_profiles
    matched_profiles=$(node - "$CONFIG_FILE" "$cwd" <<'NODE' 2>/dev/null
const fs = require("fs");
const [file, cwd] = process.argv.slice(2);
const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
const profiles = Array.isArray(cfg.profiles) ? cfg.profiles : [cfg];
const normalizedCwd = String(cwd || "");

function matchesProject(project) {
  const prefix = String(project || "").replace(/\/+$/, "");
  return !prefix || normalizedCwd === prefix || normalizedCwd.startsWith(`${prefix}/`);
}

for (const profile of profiles) {
  if (!profile || !profile.api_key) continue;
  const projects = Array.isArray(profile.projects) ? profile.projects.filter(Boolean) : [];
  if (projects.length > 0 && !projects.some(matchesProject)) continue;
  console.log([
    profile.name || "unnamed",
    profile.api_key,
    profile.api_url || "https://quarryfi.smashedstudiosllc.workers.dev",
  ].join("\t"));
}
NODE
)

    local sent=0
    while IFS=$'\t' read -r profile_name api_key api_url; do
      [ -z "$api_key" ] && continue
      send_heartbeat_to_profile "$api_key" "$api_url" "$profile_name" "$payload" &
      sent=$((sent + 1))
    done <<< "$matched_profiles"

    if [ "$sent" -gt 0 ]; then
      wait 2>/dev/null || true
    else
      append_status_audit "$project_name" "$event" "skipped:no_matching_profile"
    fi
  fi
}

timer_is_running() {
  local cwd="$1"
  local pid_file timer_pid
  pid_file=$(session_file "$cwd" "timer.pid")
  [ -f "$pid_file" ] || return 1
  timer_pid=$(cat "$pid_file" 2>/dev/null)
  [ -n "$timer_pid" ] || return 1
  kill -0 "$timer_pid" 2>/dev/null
}

start_timer_loop() {
  local cwd="$1"
  local session_id="$2"
  local pid_file
  pid_file=$(session_file "$cwd" "timer.pid")

  if timer_is_running "$cwd"; then
    return
  fi

  nohup "$0" "__timer_loop" "$cwd" "$session_id" >/dev/null 2>&1 &
  printf '%s' "$!" > "$pid_file" 2>/dev/null || true
}

stop_timer_loop() {
  local cwd="$1"
  local pid_file timer_pid
  pid_file=$(session_file "$cwd" "timer.pid")
  if [ -f "$pid_file" ]; then
    timer_pid=$(cat "$pid_file" 2>/dev/null)
    if [ -n "$timer_pid" ]; then
      kill "$timer_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file" 2>/dev/null || true
  fi
}

run_timer_loop() {
  local cwd="$1"
  local session_id="$2"
  local pid_file
  pid_file=$(session_file "$cwd" "timer.pid")
  printf '%s' "$$" > "$pid_file" 2>/dev/null || true

  while true; do
    sleep "$HEARTBEAT_INTERVAL_SECONDS" || exit 0

    if [ ! -f "$(session_file "$cwd" "session_id")" ]; then
      exit 0
    fi
    if [ "$(cat "$pid_file" 2>/dev/null)" != "$$" ]; then
      exit 0
    fi

    local now_ts duration_seconds
    now_ts=$(epoch_now)
    duration_seconds=$(duration_since_last_sent "$cwd" "$now_ts")
    if [ "$duration_seconds" -lt "$MIN_TICK_DURATION_SECONDS" ] 2>/dev/null; then
      continue
    fi

    dispatch_to_profiles "$cwd" "$session_id" "heartbeat" "$duration_seconds"
    record_last_sent "$cwd" "$now_ts"
  done
}

main() {
  local cwd session_id raw_event event_type now_ts duration_seconds
  cwd=$(get_cwd)
  [ -z "$cwd" ] && exit 0
  ensure_session_dir "$(session_dir "$cwd")"

  if [ "$CLI_EVENT" = "__timer_loop" ]; then
    run_timer_loop "$cwd" "$(get_session_id "$cwd")"
    exit 0
  fi

  session_id=$(get_session_id "$cwd")
  persist_session_context "$cwd" "$session_id"

  raw_event="${CLI_EVENT:-$EVENT_NAME_FROM_JSON}"
  [ -z "$raw_event" ] && raw_event="heartbeat"
  event_type=$(map_event "$raw_event")

  if { [ "$event_type" = "session_end" ] && [ ! -f "$(session_file "$cwd" "last_sent")" ] && [ ! -f "$(session_file "$cwd" "timer.pid")" ]; }; then
    exit 0
  fi

  now_ts=$(epoch_now)
  if [ "$raw_event" = "SessionStart" ]; then
    dispatch_to_profiles "$cwd" "$session_id" "session_start" 0
    record_last_sent "$cwd" "$now_ts"
    start_timer_loop "$cwd" "$session_id"
    exit 0
  fi

  if ! timer_is_running "$cwd"; then
    start_timer_loop "$cwd" "$session_id"
  fi

  duration_seconds=$(duration_since_last_sent "$cwd" "$now_ts")
  dispatch_to_profiles "$cwd" "$session_id" "$event_type" "$duration_seconds"
  record_last_sent "$cwd" "$now_ts"

  if [ "$event_type" = "session_end" ]; then
    stop_timer_loop "$cwd"
    cleanup_session_state "$cwd"
  fi
}

main
exit 0
