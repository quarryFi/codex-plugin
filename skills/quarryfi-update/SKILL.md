---
name: quarryfi-update
description: Update the quarryFi plugin to the latest version from GitHub
---

Update the quarryFi time tracking plugin by pulling the latest changes from GitHub.

## What to do

1. Find the plugin installation directory. Check these locations in order:
   - `~/plugins/quarryfi-time-tracker` (home-local install)
   - Search for a directory containing `.codex-plugin/plugin.json` with `"name": "quarryfi-time-tracker"` under `~/plugins/`, `~/.codex/plugins/`, or the current repo's `plugins/` directory

2. If the plugin directory is not found, tell the user:
   ```
   Could not find the quarryfi-time-tracker plugin.
   Install it first: https://github.com/quarryFi/codex-plugin#install
   ```

3. Check for updates:
   ```bash
   cd <plugin-dir>
   git fetch origin main 2>/dev/null
   LOCAL=$(git rev-parse HEAD)
   REMOTE=$(git rev-parse origin/main)
   ```

4. If `$LOCAL` equals `$REMOTE`, tell the user:
   ```
   quarryFi plugin is already up to date (version X.Y.Z).
   ```
   Read the version from `.codex-plugin/plugin.json`.

5. If there are updates available, show what's changed:
   ```bash
   git log --oneline HEAD..origin/main
   ```

6. Pull the update:
   ```bash
   git pull origin main
   ```

7. Read the new version from `.codex-plugin/plugin.json` and show:
   ```
   ✓ quarryFi plugin updated to vX.Y.Z

   Restart the Codex App to load the new version.
   ```

8. If `git pull` fails (e.g., local modifications), suggest:
   ```bash
   cd <plugin-dir>
   git stash
   git pull origin main
   git stash pop
   ```

## Error handling

- If the directory exists but is not a git repo, tell the user to re-clone.
- If there's no network, say the update check failed and to try again later.
- Never delete or overwrite the user's `~/.quarryfi/config.json` — that's separate from the plugin code.
