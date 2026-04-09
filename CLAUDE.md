# CLAUDE.md — quarryFi Codex Plugin

## Project Overview

quarryFi time tracking plugin for OpenAI Codex (CLI and App). Sends heartbeats to the quarryFi API for R&D tax credit documentation. Shares `~/.quarryfi/config.json` with the Claude Code plugin and VS Code extension.

## Architecture

- `.codex-plugin/plugin.json` — Codex plugin manifest (name: `quarryfi-time-tracker`)
- `hooks/track-session.sh` — Lifecycle hook for SessionStart, TaskStarted, TaskComplete, Stop
- `skills/quarryfi-status/SKILL.md` — Status check skill
- `skills/quarryfi-update/SKILL.md` — Self-update skill (git pull from inside Codex)
- `setup.sh` — Interactive multi-profile config setup

## Critical Rules for Updates

### Heartbeat payload — all 9 fields required, never null

Every heartbeat sent to `POST /api/heartbeat` must include ALL of these fields with real values:

| Field | Fallback | Never send |
|---|---|---|
| `source` | `"codex"` (hardcoded) | |
| `project_name` | git repo name → `"unknown"` | `null`, `""` |
| `language` | marker files → git diff → `"multi"` | `null`, `""` |
| `file_type` | git diff ext → language inference → `"multi"` | `null`, `""` |
| `branch` | `git rev-parse` → `"unknown"` | `null`, `""` |
| `editor` | `"Codex CLI"` or `"Codex App"` | `null`, `""` |
| `timestamp` | `date -u` ISO 8601 | `null`, `""` |
| `duration_seconds` | `0` on start events | `null`, `""` |
| `session_id` | env var → persisted file → generate | `null`, `""` |

This applies everywhere — including `setup.sh`'s verify_key function, which must send a complete payload (not a minimal one) or the API returns 400.

### Session files use stable paths, not PID

Session files (`*.start`, `*.sid`) are stored at `/tmp/quarryfi-codex-{hash}` where hash is derived from `shasum` of the project directory. NEVER use `$$` (PID) — each hook invocation is a separate process.

### Config format is shared

`~/.quarryfi/config.json` is identical across the Codex plugin, Claude Code plugin, and VS Code extension. Any config format changes must be coordinated across all three repos.

### Plugin folder name must match manifest name

The install directory must be `quarryfi-time-tracker` to match the `"name"` field in `.codex-plugin/plugin.json`. The marketplace entry `source.path` must point to this folder name.

## Version Bumping

Bump version in `.codex-plugin/plugin.json` when:
- **Patch** (0.2.x): bug fixes, doc updates
- **Minor** (0.x.0): new features, new fields, new skills
- **Major** (x.0.0): breaking config changes, removed fields

Current version: see `.codex-plugin/plugin.json`

## Testing

- `bash -n hooks/track-session.sh` — syntax check
- `bash -n setup.sh` — syntax check
- Test verify_key by running `setup.sh` with a real key — must get HTTP 200, not 400
