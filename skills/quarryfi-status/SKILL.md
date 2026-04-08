---
name: quarryfi-status
description: Check your quarryFi R&D time tracking status and session summary
---

Show the user's quarryFi R&D tracking status by querying the quarryFi API.

## What to do

1. Read the user's config from `~/.quarryfi/config.json` to get `api_key` and `api_url`.
2. If the config file doesn't exist, tell the user to run setup:
   ```
   curl -fsSL https://raw.githubusercontent.com/quarryFi/codex-plugin/main/setup.sh | bash
   ```
3. Query the status endpoint:
   ```bash
   curl -s -H "Authorization: Bearer $API_KEY" "$API_URL/api/status"
   ```
4. Display the results in a readable summary including:
   - Today's tracked R&D time
   - Current week total
   - Active project(s)
   - Recent sessions
5. If the API returns an error, show the HTTP status and suggest the user verify their API key.

## Response format

Present the data as a clean summary, for example:

```
quarryFi R&D Tracking Status
─────────────────────────────
Today:      2h 34m
This week:  12h 15m
Project:    codex-plugin
Sessions:   3 today

Source: Codex CLI
```

Adapt the format based on what fields the API actually returns. Keep it concise.
