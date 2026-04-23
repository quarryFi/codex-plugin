#!/usr/bin/env bash
# quarryFi session tracker for OpenAI Codex
# Called by Codex on lifecycle events: SessionStart, TaskStarted, TaskComplete, Stop
#
# Supports multi-profile config with project-to-key routing.
# Reads profiles from ~/.quarryfi/config.json
# Sends heartbeats to POST /api/heartbeat for each matching profile.
# Appends each heartbeat to ~/.quarryfi/audit.log (capped at 1MB).
# All errors are silenced — tracking must never interrupt the user.
#
# Required heartbeat fields (all guaranteed non-null):
#   source, project_name, language, file_type, branch,
#   editor, timestamp, duration_seconds, session_id

set -o pipefail

CONFIG_FILE="$HOME/.quarryfi/config.json"
AUDIT_LOG="$HOME/.quarryfi/audit.log"
AUDIT_MAX_BYTES=1048576  # 1MB
EVENT_JSON=$(cat 2>/dev/null || true)

# ── Session file paths ───────────────────────────────────────────────────────
# Use a stable path derived from the project directory, NOT $$ (PID).
# Each hook invocation is a separate process — PID-based paths break across
# SessionStart → TaskComplete because the PID changes every invocation.

session_dir() {
  local cwd
  cwd=$(get_cwd)
  local hash
  # Stable hash of the project directory for unique-but-consistent filenames
  hash=$(printf '%s' "$cwd" | shasum -a 256 2>/dev/null | cut -c1-12)
  echo "/tmp/quarryfi-codex-${hash}"
}

# ── Helpers ──────────────────────────────────────────────────────────────────

# Portable JSON string extraction (no jq dependency).
# Usage: json_string "$json" "field_name"
json_string() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

EVENT_NAME_FROM_JSON=$(json_string "$EVENT_JSON" "hook_event_name")
EVENT_CWD_FROM_JSON=$(json_string "$EVENT_JSON" "cwd")
EVENT_SESSION_ID_FROM_JSON=$(json_string "$EVENT_JSON" "session_id")
EVENT_FILE_PATH_FROM_JSON=$(json_string "$EVENT_JSON" "file_path")

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

# Detect legacy single-key config format.
is_legacy_config() {
  grep -q '"profiles"' "$CONFIG_FILE" 2>/dev/null && return 1
  grep -q '"api_key"' "$CONFIG_FILE" 2>/dev/null && return 0
  return 1
}

get_cwd() {
  if [ -n "$EVENT_CWD_FROM_JSON" ]; then
    echo "$EVENT_CWD_FROM_JSON"
    return
  fi
  echo "${CODEX_PROJECT_DIR:-${CODEX_CWD:-$(pwd)}}"
}

# ── Field resolvers (every field guaranteed non-null) ────────────────────────

get_project_name() {
  local name
  name=$(basename "$(get_cwd)")
  # basename of "/" is empty; fall back to git repo name, then "unknown"
  if [ -z "$name" ] || [ "$name" = "/" ]; then
    name=$(git -C "$(get_cwd)" rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
  fi
  echo "${name:-unknown}"
}

get_editor() {
  # Codex sets CODEX_CLIENT to identify CLI vs App
  case "${CODEX_CLIENT:-cli}" in
    app|desktop) echo "Codex App" ;;
    *)           echo "Codex CLI" ;;
  esac
}

get_branch() {
  local branch
  branch=$(git -C "$(get_cwd)" rev-parse --abbrev-ref HEAD 2>/dev/null)
  echo "${branch:-unknown}"
}

get_language() {
  local dir
  dir=$(get_cwd)

  if [ -n "$EVENT_FILE_PATH_FROM_JSON" ]; then
    local ext
    ext="${EVENT_FILE_PATH_FROM_JSON##*.}"
    if [ -n "$ext" ] && [ "$ext" != "$EVENT_FILE_PATH_FROM_JSON" ]; then
      case "$ext" in
        ts|tsx)   echo "typescript"; return ;;
        js|jsx)   echo "javascript"; return ;;
        py)       echo "python"; return ;;
        rs)       echo "rust"; return ;;
        go)       echo "go"; return ;;
        rb)       echo "ruby"; return ;;
        java|kt)  echo "java"; return ;;
        php)      echo "php"; return ;;
        swift)    echo "swift"; return ;;
        c|cpp|h)  echo "c/cpp"; return ;;
        sh|bash|zsh) echo "shell"; return ;;
        json)     echo "json"; return ;;
        md|markdown) echo "markdown"; return ;;
      esac
    fi
  fi

  # 1. Check project marker files for primary language
  if [ -f "$dir/package.json" ] || [ -f "$dir/tsconfig.json" ]; then
    if [ -f "$dir/tsconfig.json" ]; then echo "typescript"; return; fi
    echo "javascript"; return
  fi
  if [ -f "$dir/Cargo.toml" ];    then echo "rust";       return; fi
  if [ -f "$dir/go.mod" ];        then echo "go";         return; fi
  if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ] || [ -f "$dir/setup.cfg" ]; then
    echo "python"; return
  fi
  if [ -f "$dir/Gemfile" ];        then echo "ruby";       return; fi
  if [ -f "$dir/build.gradle" ] || [ -f "$dir/pom.xml" ]; then echo "java"; return; fi
  if [ -f "$dir/mix.exs" ];        then echo "elixir";     return; fi
  if [ -f "$dir/composer.json" ];   then echo "php";        return; fi
  if [ -f "$dir/Package.swift" ];   then echo "swift";      return; fi
  if [ -f "$dir/CMakeLists.txt" ] || [ -f "$dir/Makefile" ]; then echo "c/cpp"; return; fi

  # 2. Check recent git changes for file extensions
  local recent_ext
  recent_ext=$(git -C "$dir" diff --name-only HEAD~3 HEAD 2>/dev/null | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  if [ -n "$recent_ext" ]; then
    case "$recent_ext" in
      ts|tsx)   echo "typescript"; return ;;
      js|jsx)   echo "javascript"; return ;;
      py)       echo "python";     return ;;
      rs)       echo "rust";       return ;;
      go)       echo "go";         return ;;
      rb)       echo "ruby";       return ;;
      java|kt)  echo "java";       return ;;
      php)      echo "php";        return ;;
      swift)    echo "swift";      return ;;
      c|cpp|h)  echo "c/cpp";      return ;;
      sh|bash)  echo "shell";      return ;;
    esac
  fi

  # 3. Never null — default to "multi"
  echo "multi"
}

get_file_type() {
  local dir
  dir=$(get_cwd)

  if [ -n "$EVENT_FILE_PATH_FROM_JSON" ]; then
    local event_ext
    event_ext="${EVENT_FILE_PATH_FROM_JSON##*.}"
    if [ -n "$event_ext" ] && [ "$event_ext" != "$EVENT_FILE_PATH_FROM_JSON" ]; then
      echo "$event_ext"
      return
    fi
  fi

  # 1. Check recent git changes for the dominant file extension
  local recent_ext
  recent_ext=$(git -C "$dir" diff --name-only HEAD~3 HEAD 2>/dev/null | grep '\.' | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  if [ -n "$recent_ext" ]; then
    # If there are multiple distinct extensions in recent changes, use "multi"
    local ext_count
    ext_count=$(git -C "$dir" diff --name-only HEAD~3 HEAD 2>/dev/null | grep '\.' | sed 's/.*\.//' | sort -u | wc -l | tr -d ' ')
    if [ "$ext_count" -gt 3 ]; then
      echo "multi"
    else
      echo "$recent_ext"
    fi
    return
  fi

  # 2. Check staged files
  recent_ext=$(git -C "$dir" diff --cached --name-only 2>/dev/null | grep '\.' | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  if [ -n "$recent_ext" ]; then
    echo "$recent_ext"
    return
  fi

  # 3. Infer from language as last resort
  local lang
  lang=$(get_language)
  case "$lang" in
    typescript)  echo "ts" ;;
    javascript)  echo "js" ;;
    python)      echo "py" ;;
    rust)        echo "rs" ;;
    go)          echo "go" ;;
    ruby)        echo "rb" ;;
    java)        echo "java" ;;
    php)         echo "php" ;;
    swift)       echo "swift" ;;
    c/cpp)       echo "cpp" ;;
    shell)       echo "sh" ;;
    *)           echo "multi" ;;
  esac
}

get_session_id() {
  local sf
  sf=$(session_dir)

  # 1. Prefer hook payload session ID
  if [ -n "$EVENT_SESSION_ID_FROM_JSON" ]; then
    echo "$EVENT_SESSION_ID_FROM_JSON" > "${sf}.sid" 2>/dev/null || true
    echo "$EVENT_SESSION_ID_FROM_JSON"
    return
  fi

  # 2. Prefer Codex-provided session ID
  if [ -n "${CODEX_SESSION_ID:-}" ]; then
    # Persist it so subsequent hooks without the env var can still read it
    echo "$CODEX_SESSION_ID" > "${sf}.sid" 2>/dev/null || true
    echo "$CODEX_SESSION_ID"
    return
  fi

  # 3. Read previously persisted session ID
  if [ -f "${sf}.sid" ]; then
    cat "${sf}.sid"
    return
  fi

  # 4. Generate a new one and persist it
  local new_id="codex-$(date +%s)-${RANDOM:-0}"
  echo "$new_id" > "${sf}.sid" 2>/dev/null || true
  echo "$new_id"
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

  local record
  record=$(printf '{"ts":"%s","profile":"%s","api_url":"%s","http_status":"%s","payload":%s}' \
    "$(timestamp_utc)" "$profile_name" "$api_url" "$http_status" "$payload")

  rotate_audit_log
  echo "$record" >> "$AUDIT_LOG" 2>/dev/null || true
}

append_status_audit() {
  local project_name="$1"
  local event_name="$2"
  local status="$3"
  local record
  record=$(printf '{"ts":"%s","project":"%s","event":"%s","status":"%s"}' \
    "$(timestamp_utc)" "$project_name" "$event_name" "$status")

  rotate_audit_log
  echo "$record" >> "$AUDIT_LOG" 2>/dev/null || true
}

# ── Heartbeat ────────────────────────────────────────────────────────────────

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

# ── Profile dispatch ─────────────────────────────────────────────────────────

dispatch_to_profiles() {
  local event="$1"
  local duration="$2"

  # Resolve all fields once (each guaranteed non-null)
  local now
  now=$(timestamp_utc)
  local session_id
  session_id=$(get_session_id)
  local project_name
  project_name=$(get_project_name)
  local editor
  editor=$(get_editor)
  local branch
  branch=$(get_branch)
  local language
  language=$(get_language)
  local file_type
  file_type=$(get_file_type)
  local cwd
  cwd=$(get_cwd)

  local payload
  payload=$(build_payload "$event" "$duration" "$now" "$session_id" \
    "$project_name" "$editor" "$branch" "$language" "$file_type")

  if is_legacy_config; then
    local api_key api_url
    api_key=$(json_string "$(cat "$CONFIG_FILE")" "api_key")
    api_url=$(json_string "$(cat "$CONFIG_FILE")" "api_url")
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
    return
  fi

  local config_content
  config_content=$(cat "$CONFIG_FILE")

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

  if [ "$sent" -gt 0 ]; then
    wait 2>/dev/null || true
  else
    append_status_audit "$project_name" "$event" "skipped:no_matching_profile"
  fi
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

duration_since_last_event() {
  local sf="$1"
  local now_ts="$2"
  local duration=0

  if [ -f "${sf}.last" ]; then
    local last_ts
    last_ts=$(cat "${sf}.last" 2>/dev/null)
    if [ -n "$last_ts" ]; then
      duration=$(( now_ts - last_ts ))
    fi
  fi

  clamp_duration "$duration"
}

record_last_event() {
  local sf="$1"
  local now_ts="$2"
  echo "$now_ts" > "${sf}.last" 2>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  if [ ! -f "$CONFIG_FILE" ]; then
    exit 0
  fi

  local event="${1:-${CODEX_HOOK_EVENT:-${EVENT_NAME_FROM_JSON:-unknown}}}"
  local sf
  sf=$(session_dir)
  local now_ts
  now_ts=$(date +%s 2>/dev/null || echo 0)
  local duration=0

  case "$event" in
    SessionStart)
      get_session_id > /dev/null
      record_last_event "$sf" "$now_ts"
      dispatch_to_profiles "$event" 0
      ;;

    Stop)
      duration=$(duration_since_last_event "$sf" "$now_ts")
      dispatch_to_profiles "$event" "$duration"
      rm -f "${sf}.last" "${sf}.sid"
      ;;

    *)
      duration=$(duration_since_last_event "$sf" "$now_ts")
      dispatch_to_profiles "$event" "$duration"
      record_last_event "$sf" "$now_ts"
      ;;
  esac
}

# Run silently — never let tracking errors propagate to Codex
main "$@" 2>/dev/null
exit 0
