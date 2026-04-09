#!/usr/bin/env bash
# quarryFi plugin setup — multi-profile configuration
# Writes ~/.quarryfi/config.json with one or more company profiles.
# Shared by the Claude Code and Codex plugins.

set -euo pipefail

CONFIG_DIR="$HOME/.quarryfi"
CONFIG_FILE="$CONFIG_DIR/config.json"
DEFAULT_API_URL="https://quarryfi.smashedstudiosllc.workers.dev"

# ── Helpers ──────────────────────────────────────────────────────────────────

print_header() {
  echo ""
  echo "  quarryFi Plugin Setup"
  echo "  ─────────────────────"
  echo ""
}

validate_key() {
  local key="$1"
  if [[ ! "$key" =~ ^qf_[a-f0-9]{40}$ ]]; then
    echo "  ✗ Invalid key format. Expected: qf_ followed by 40 hex characters."
    echo "  Example: qf_a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    return 1
  fi
  return 0
}

verify_key() {
  local api_key="$1"
  local api_url="$2"
  echo "  Verifying API key..."
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${api_key}" \
    -H "Content-Type: application/json" \
    -d '{"heartbeats":[{"source":"codex","project_name":"setup-verify","language":"multi","file_type":"multi","branch":"unknown","editor":"Codex CLI","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","duration_seconds":0,"session_id":"setup-'"$$"'"}]}' \
    "${api_url}/api/heartbeat" 2>/dev/null || echo "000")

  if [ "$status" = "200" ]; then
    echo "  ✓ API key is valid."
    return 0
  elif [ "$status" = "401" ]; then
    echo "  ✗ API key was rejected."
    return 1
  else
    echo "  ⚠ Could not reach API (HTTP ${status}). Key saved — will retry on next use."
    return 0
  fi
}

# JSON-escape a string (handles quotes and backslashes)
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ── Profile collection ───────────────────────────────────────────────────────

collect_profile() {
  local profile_num="$1"

  echo ""
  echo "  ── Profile ${profile_num} ──"
  echo ""

  # Profile name
  read -rp "  Company/profile name: " profile_name
  if [ -z "$profile_name" ]; then
    echo "  ✗ Name is required."
    return 1
  fi

  # API key
  echo ""
  echo "  Get your API key from your quarryFi dashboard:"
  echo "  ${DEFAULT_API_URL}/dashboard"
  echo ""
  read -rp "  API Key (qf_...): " api_key
  if ! validate_key "$api_key"; then
    return 1
  fi

  # API URL
  read -rp "  API URL [${DEFAULT_API_URL}]: " api_url
  api_url="${api_url:-$DEFAULT_API_URL}"

  # Project directories
  echo ""
  echo "  Project directories for this profile (one per line, blank to finish)."
  echo "  Leave empty to match ALL projects (useful for single-company setups)."
  echo ""

  local projects=()
  while true; do
    read -rp "  Project path: " project_path
    if [ -z "$project_path" ]; then
      break
    fi
    # Expand ~ to $HOME
    project_path="${project_path/#\~/$HOME}"
    # Resolve to absolute path if possible
    if [ -d "$project_path" ]; then
      project_path=$(cd "$project_path" && pwd)
    fi
    projects+=("$project_path")
    echo "  + Added: $project_path"
  done

  # Verify key
  if ! verify_key "$api_key" "$api_url"; then
    read -rp "  Continue anyway? [y/N] " cont
    if [[ ! "$cont" =~ ^[Yy]$ ]]; then
      return 1
    fi
  fi

  # Build JSON fragment for this profile
  local projects_json="[]"
  if [ ${#projects[@]} -gt 0 ]; then
    projects_json="["
    local first=1
    for p in "${projects[@]}"; do
      if [ "$first" -eq 1 ]; then first=0; else projects_json+=", "; fi
      projects_json+="\"$(json_escape "$p")\""
    done
    projects_json+="]"
  fi

  # Store in global array via temp file (bash 3 compat)
  cat >> "$PROFILES_TMP" <<EOF
    {
      "name": "$(json_escape "$profile_name")",
      "api_key": "${api_key}",
      "api_url": "$(json_escape "$api_url")",
      "projects": ${projects_json}
    }
EOF

  echo ""
  echo "  ✓ Profile \"${profile_name}\" configured."
  return 0
}

# ── Migration ────────────────────────────────────────────────────────────────

migrate_legacy_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    return 1
  fi

  # Check if already multi-profile
  if grep -q '"profiles"' "$CONFIG_FILE" 2>/dev/null; then
    return 1
  fi

  # Check if it's a legacy single-key config
  if ! grep -q '"api_key"' "$CONFIG_FILE" 2>/dev/null; then
    return 1
  fi

  echo "  Found legacy single-key config."
  read -rp "  Migrate to multi-profile format? [Y/n] " migrate
  if [[ "$migrate" =~ ^[Nn]$ ]]; then
    return 1
  fi

  local old_key old_url
  old_key=$(grep -o '"api_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*:.*"\(.*\)"/\1/')
  old_url=$(grep -o '"api_url"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*:.*"\(.*\)"/\1/')

  if [ -z "$old_key" ]; then
    echo "  ✗ Could not read existing key."
    return 1
  fi

  read -rp "  Name for existing profile [Default]: " name
  name="${name:-Default}"

  echo ""
  echo "  Migrating existing key to profile \"${name}\" (matches all projects)."

  # Backup old config
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

  cat > "$CONFIG_FILE" <<EOF
{
  "profiles": [
    {
      "name": "$(json_escape "$name")",
      "api_key": "${old_key}",
      "api_url": "${old_url:-$DEFAULT_API_URL}",
      "projects": []
    }
  ]
}
EOF

  chmod 600 "$CONFIG_FILE"
  echo "  ✓ Migrated. Backup saved to ${CONFIG_FILE}.bak"
  echo ""

  read -rp "  Add another profile? [y/N] " add_more
  if [[ "$add_more" =~ ^[Yy]$ ]]; then
    return 0  # signal caller to continue adding
  fi
  return 2  # signal caller we're done
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  print_header
  mkdir -p "$CONFIG_DIR"

  PROFILES_TMP=$(mktemp)
  trap 'rm -f "$PROFILES_TMP"' EXIT

  # Handle existing config
  if [ -f "$CONFIG_FILE" ]; then
    local migrate_result=0
    migrate_legacy_config || migrate_result=$?

    if [ "$migrate_result" -eq 2 ]; then
      # Migration done, user doesn't want more profiles
      echo ""
      echo "  Setup complete. Config at $CONFIG_FILE"
      echo ""
      return 0
    elif [ "$migrate_result" -eq 1 ]; then
      # Already multi-profile or user declined migration
      if grep -q '"profiles"' "$CONFIG_FILE" 2>/dev/null; then
        echo "  Existing multi-profile config found."
        echo ""
        echo "  1) Add a new profile"
        echo "  2) Start fresh (replace all profiles)"
        echo "  3) Cancel"
        echo ""
        read -rp "  Choice [1/2/3]: " choice
        case "$choice" in
          1)
            # We'll append to existing profiles below
            ;;
          2)
            echo "  Starting fresh..."
            cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
            ;;
          *)
            echo "  Setup cancelled."
            return 0
            ;;
        esac
      fi
    fi
    # migrate_result 0 means migration succeeded, continue to add more profiles
  fi

  # Collect profiles
  local profile_num=1
  while true; do
    if collect_profile "$profile_num"; then
      profile_num=$((profile_num + 1))
    else
      echo "  Skipping profile."
    fi

    echo ""
    read -rp "  Add another profile? [y/N] " more
    if [[ ! "$more" =~ ^[Yy]$ ]]; then
      break
    fi
  done

  # Check we have at least one new profile
  if [ ! -s "$PROFILES_TMP" ]; then
    echo "  No profiles configured."
    return 1
  fi

  # Build final config JSON
  # If appending to existing config, merge profile arrays
  local existing_profiles=""
  if [ -f "$CONFIG_FILE" ] && grep -q '"profiles"' "$CONFIG_FILE" 2>/dev/null; then
    # Extract existing profile objects (everything between first [ and last ])
    existing_profiles=$(sed -n '/"profiles"/,/]/p' "$CONFIG_FILE" | grep -v '"profiles"' | grep -v '^\s*\]' | sed '/^$/d')
  fi

  # Combine profiles
  local all_profiles=""
  if [ -n "$existing_profiles" ]; then
    # Ensure existing profiles end with comma
    all_profiles="${existing_profiles}"
    # Check if existing ends with a closing brace (need comma)
    if echo "$all_profiles" | tail -1 | grep -q '}[[:space:]]*$'; then
      all_profiles=$(echo "$all_profiles" | sed '$ s/}[[:space:]]*$/},/')
    fi
    all_profiles="${all_profiles}
$(cat "$PROFILES_TMP")"
  else
    all_profiles=$(cat "$PROFILES_TMP")
  fi

  # Separate profiles with commas
  local formatted_profiles
  formatted_profiles=$(echo "$all_profiles" | awk '
    /^[[:space:]]*\{/ { if (NR > 1 && !comma_added) printf ",\n"; comma_added=0 }
    { print }
    /^[[:space:]]*\}/ { comma_added=0 }
  ')

  cat > "$CONFIG_FILE" <<EOF
{
  "profiles": [
${formatted_profiles}
  ]
}
EOF

  chmod 600 "$CONFIG_FILE"

  echo ""
  echo "  ✓ Config written to $CONFIG_FILE"
  echo "  Profiles: ${profile_num}"
  echo ""
  echo "  This config is shared by the Claude Code and Codex plugins."
  echo "  Both tools will route heartbeats based on your project mappings."
  echo ""
}

main "$@"
