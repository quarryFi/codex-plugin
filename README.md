# quarryFi Codex Plugin

R&D time tracking for [OpenAI Codex](https://openai.com/codex). Automatically tracks coding sessions in Codex CLI and Codex App, sending heartbeats to your quarryFi account for tax credit documentation.

## Install

### Option 1: Codex Plugin Directory

Search for **quarryFi** in Codex's `/plugins` command and install directly.

### Option 2: Manual

Clone this repo and register it as a local plugin:

```bash
git clone https://github.com/quarryFi/codex-plugin.git
# Then add the plugin path in Codex settings or via the plugin marketplace
```

## Configuration

This plugin uses the same `~/.quarryfi/config.json` as the Claude Code plugin. If you haven't configured it yet:

```bash
curl -fsSL https://raw.githubusercontent.com/quarryFi/codex-plugin/main/setup.sh | bash
```

You'll need your API key from your [quarryFi dashboard](https://quarryfi.smashedstudiosllc.workers.dev/dashboard).

The config file stores:

```json
{
  "api_key": "qf_...",
  "api_url": "https://quarryfi.smashedstudiosllc.workers.dev"
}
```

## What It Tracks

- **Session duration** — start and end of each Codex task/session
- **Project name** — derived from your working directory
- **Editor type** — Codex CLI or Codex App
- **Branch** — current git branch
- **Language** — best-effort detection from project files

### Privacy

- Only project-level metadata is sent (project name, branch, duration)
- No source code, file contents, prompts, or AI responses are transmitted
- Data goes only to your quarryFi account at the API URL in your config
- All tracking runs silently — errors never interrupt your workflow

## How It Works

The plugin hooks into Codex lifecycle events:

| Event | Action |
|-------|--------|
| `SessionStart` / `TaskStarted` | Records start time, sends start heartbeat |
| `TaskComplete` / `Stop` | Calculates duration, sends completion heartbeat |

Heartbeats are sent to `POST /api/heartbeat` with source `"codex"`.

## Skills

### quarryfi-status

Check your tracking status from within Codex:

> "Check my quarryFi R&D tracking status"

Shows today's tracked time, weekly totals, and recent sessions.

## Plugin Structure

```
codex-plugin/
├── .codex-plugin/
│   └── plugin.json          # Plugin manifest (Codex spec)
├── hooks/
│   └── track-session.sh     # Lifecycle event handler
├── skills/
│   └── quarryfi-status/
│       └── SKILL.md          # Status check skill
├── setup.sh                  # Shared config setup
└── README.md
```

## Compatibility Note

Codex's plugin system launched in March 2026 and is actively evolving. The hook system in this plugin follows the documented lifecycle events. If Codex updates its plugin API, this plugin may need updates — check the [Codex plugin docs](https://developers.openai.com/codex/plugins/build) for the latest spec.

## License

MIT
