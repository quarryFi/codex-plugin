#!/usr/bin/env bash
# quarryFi plugin setup
# Writes ~/.quarryfi/config.json with the user's API key and API URL.
# Used by the Claude Code and Codex plugins.

set -euo pipefail

CONFIG_DIR="$HOME/.quarryfi"
CONFIG_FILE="$CONFIG_DIR/config.json"
DEFAULT_API_URL="https://quarryfi.smashedstudiosllc.workers.dev"

echo ""
echo "  quarryFi Plugin Setup"
echo "  ─────────────────────"
echo ""

# Check for existing config
if [ -f "$CONFIG_FILE" ]; then
  echo "  Existing config found at $CONFIG_FILE"
  read -rp "  Overwrite? [y/N] " overwrite
  if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
    echo "  Setup cancelled."
    exit 0
  fi
fi

# Prompt for API key
echo ""
echo "  Get your API key from your QuarryFi dashboard:"
echo "  ${DEFAULT_API_URL}/dashboard"
echo ""
read -rp "  API Key (qf_...): " api_key

# Validate key format
if [[ ! "$api_key" =~ ^qf_[a-f0-9]{40}$ ]]; then
  echo ""
  echo "  ✗ Invalid key format. Expected: qf_ followed by 40 hex characters."
  echo "  Example: qf_a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
  exit 1
fi

# Prompt for API URL (with default)
read -rp "  API URL [${DEFAULT_API_URL}]: " api_url
api_url="${api_url:-$DEFAULT_API_URL}"

# Write config
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
{
  "api_key": "${api_key}",
  "api_url": "${api_url}"
}
EOF

chmod 600 "$CONFIG_FILE"

echo ""
echo "  ✓ Config written to $CONFIG_FILE"
echo ""

# Verify the key works
echo "  Verifying API key..."
status=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${api_key}" \
  -H "Content-Type: application/json" \
  -d '{"heartbeats":[{"source":"vscode","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","duration_seconds":0}]}' \
  "${api_url}/api/heartbeat" 2>/dev/null || echo "000")

if [ "$status" = "200" ]; then
  echo "  ✓ API key is valid. You're all set!"
elif [ "$status" = "401" ]; then
  echo "  ✗ API key was rejected. Check your key and try again."
  exit 1
else
  echo "  ⚠ Could not reach the API (HTTP ${status}). Config saved — the plugin will retry on next use."
fi

echo ""
