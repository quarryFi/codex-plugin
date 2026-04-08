---
name: quarryfi-status
description: Check quarryFi R&D tracking status across all configured company profiles
---

Show the user's quarryFi R&D tracking status across all configured profiles.

## What to do

1. Read `~/.quarryfi/config.json`. If it doesn't exist, tell the user to run setup:
   ```
   curl -fsSL https://raw.githubusercontent.com/quarryFi/codex-plugin/main/setup.sh | bash
   ```

2. Detect the config format:
   - **Multi-profile** (has `"profiles"` array): iterate each profile.
   - **Legacy** (has top-level `"api_key"`): treat as a single unnamed profile.

3. For each profile, display:
   - Profile name
   - API URL
   - Mapped project directories (or "all projects" if empty)
   - Whether the current working directory matches this profile

4. For each profile, query the status endpoint:
   ```bash
   curl -s -H "Authorization: Bearer $API_KEY" "$API_URL/api/status"
   ```

5. Display results per profile:
   - Today's tracked R&D time
   - Current week total
   - Active projects
   - Recent sessions

6. Show audit log summary:
   - Check if `~/.quarryfi/audit.log` exists
   - Show the count of recent entries and last heartbeat timestamp
   - If the user asks for details, show the last 10 lines of the audit log

7. If any API returns an error, show the HTTP status and suggest verifying the API key.

## Response format

```
quarryFi R&D Tracking Status
═════════════════════════════

Profile: Acme Corp
  API:       https://quarryfi.smashedstudiosllc.workers.dev
  Projects:  /Users/me/work/acme-api, /Users/me/work/acme-frontend
  Match:     ✓ (current directory matches)
  Today:     2h 34m
  This week: 12h 15m
  Sessions:  3 today

Profile: Personal Projects
  API:       https://quarryfi.smashedstudiosllc.workers.dev
  Projects:  all (catch-all)
  Match:     ✗
  Today:     0h 45m
  This week: 3h 20m

─────────────────────────────
Audit log: 142 entries, last heartbeat 2 min ago
Source: Codex CLI
```

Adapt based on actual API response fields. Keep it concise.
