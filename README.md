# quarryFi Codex Plugin

R&D time tracking for [OpenAI Codex](https://openai.com/codex). Automatically tracks coding sessions in Codex CLI and Codex App, sending heartbeats to your quarryFi account for tax credit documentation.

Supports **multiple company profiles** with project-to-key routing — freelancers and consultants can track R&D time for different clients from a single config file.

## Install

### From the Codex App

1. Open the **Plugin Directory** (sidebar or settings)
2. Switch the marketplace source to **Personal Plugins** (if you've registered the plugin locally — see below) or search for **quarryfi**
3. Find **quarryFi Time Tracker** and click **Add to Codex**
4. If prompted to authenticate, enter your quarryFi API key (get one from your [dashboard](https://quarryfi.smashedstudiosllc.workers.dev/dashboard))
5. The plugin is active immediately — bundled skills and hooks start working as soon as it's installed

You can enable/disable the plugin at any time from the plugin directory. Codex stores your preference in `~/.codex/config.toml`.
Installing from Personal Plugins does not mean Codex will auto-pull future GitHub changes. If the plugin lives in a local clone, that local clone still needs to be updated.

> **First time?** The plugin needs to be registered in a marketplace before it appears in the app. Follow the Home-Local or Repo-Local setup below to make it discoverable, then use the app flow above to install it.

---

### Home-Local Setup (Codex App / Codex CLI)

The plugin folder name must match the `"name"` in `.codex-plugin/plugin.json`, which is `quarryfi-time-tracker`.

Use this to make the plugin available across all your projects.

1. Clone the plugin:

```bash
mkdir -p ~/plugins
git clone https://github.com/quarryFi/codex-plugin.git ~/plugins/quarryfi-time-tracker
```

2. Register it in your personal marketplace:

```bash
mkdir -p ~/.agents/plugins
```

If `~/.agents/plugins/marketplace.json` **doesn't exist yet**, create it:

```json
{
  "name": "personal-plugins",
  "interface": {
    "displayName": "Personal Plugins"
  },
  "plugins": [
    {
      "name": "quarryfi-time-tracker",
      "source": {
        "source": "local",
        "path": "./plugins/quarryfi-time-tracker"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Productivity"
    }
  ]
}
```

> **Note:** The `source.path` is relative to the marketplace file's parent directory (`~/`). If you already have a `marketplace.json`, add the `quarryfi-time-tracker` entry to the existing `plugins` array.

3. Restart the Codex App. The plugin should appear in the plugin directory under "Personal Plugins".

### Repo-Local Install

To scope the plugin to a single project:

1. Clone into your repo's plugin directory:

```bash
mkdir -p plugins
git clone https://github.com/quarryFi/codex-plugin.git plugins/quarryfi-time-tracker
```

2. Add a marketplace file at `<repo-root>/.agents/plugins/marketplace.json`:

```json
{
  "name": "project-plugins",
  "interface": {
    "displayName": "Project Plugins"
  },
  "plugins": [
    {
      "name": "quarryfi-time-tracker",
      "source": {
        "source": "local",
        "path": "./plugins/quarryfi-time-tracker"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Productivity"
    }
  ]
}
```

### Verify

After installing, confirm two things:

- Manifest exists at `<plugin-folder>/.codex-plugin/plugin.json`
- A marketplace file includes an entry pointing to the plugin folder

## Configuration

This plugin shares `~/.quarryfi/config.json` with the Claude Code plugin. If you use both tools, you only need to configure once.

### Quick Setup

```bash
curl -fsSL https://raw.githubusercontent.com/quarryFi/codex-plugin/main/setup.sh | bash
```

The setup wizard walks you through creating profiles interactively. You'll need your API key from your [quarryFi dashboard](https://quarryfi.smashedstudiosllc.workers.dev/dashboard).

### Config Format

```json
{
  "profiles": [
    {
      "name": "Acme Corp",
      "api_key": "qf_...",
      "api_url": "https://quarryfi.smashedstudiosllc.workers.dev",
      "projects": ["/Users/me/work/acme-api", "/Users/me/work/acme-frontend"]
    },
    {
      "name": "Personal",
      "api_key": "qf_...",
      "api_url": "https://quarryfi.smashedstudiosllc.workers.dev",
      "projects": []
    }
  ]
}
```

Each profile maps an API key to specific project directories. When a hook fires, the script matches the current working directory against profiles and sends heartbeats to all matching endpoints.

### Multi-Company Setup

If you work for multiple companies, each with their own quarryFi account:

1. Run `setup.sh` and create a profile for each company
2. Add the project directories you work on for each company
3. Leave `"projects": []` on one profile to use it as a catch-all for unmapped directories

**How routing works:**

- The plugin checks your current working directory against each profile's `projects` list
- Match is **prefix-based** — `/Users/me/work/acme` matches `/Users/me/work/acme-api/src/`
- A heartbeat is sent to **every** matching profile (a directory can match multiple profiles)
- If no profiles match, the heartbeat is silently skipped
- Profiles with an empty `projects` array match all directories (catch-all)

**Example:** A freelancer working for Acme Corp and Beta Inc:

```json
{
  "profiles": [
    {
      "name": "Acme Corp",
      "api_key": "qf_acme_key_here",
      "api_url": "https://quarryfi.smashedstudiosllc.workers.dev",
      "projects": ["/Users/me/clients/acme"]
    },
    {
      "name": "Beta Inc",
      "api_key": "qf_beta_key_here",
      "api_url": "https://quarryfi.smashedstudiosllc.workers.dev",
      "projects": ["/Users/me/clients/beta"]
    }
  ]
}
```

### Backward Compatibility

The old single-key format is still supported:

```json
{
  "api_key": "qf_...",
  "api_url": "https://quarryfi.smashedstudiosllc.workers.dev"
}
```

When detected, it's treated as one profile that matches all projects. Running `setup.sh` will offer to migrate it to the multi-profile format.

## What It Tracks

- **Session duration** — start and end of each Codex task/session
- **Project name** — derived from your working directory
- **Editor type** — Codex CLI or Codex App
- **Branch** — current git branch
- **Language** — best-effort detection from project files

### Audit Log

Every heartbeat is appended to `~/.quarryfi/audit.log` as one JSON line per event:

```json
{"ts":"2026-04-08T12:00:00Z","profile":"Acme Corp","api_url":"https://...","http_status":"200","payload":{...}}
```

- Capped at 1MB (older entries are automatically rotated out)
- Fire-and-forget — audit logging never blocks or errors the hook
- Useful for debugging and verifying heartbeats are being sent

### Privacy

- Only project-level metadata is sent (project name, branch, duration)
- No source code, file contents, prompts, or AI responses are transmitted
- Data goes only to the API URL configured in each profile
- All tracking runs silently — errors never interrupt your workflow
- The local audit log stays on your machine and is never transmitted

## How It Works

The plugin hooks into Codex lifecycle events:

| Event | Action |
|-------|--------|
| `SessionStart` / `TaskStarted` | Records start time, sends start heartbeat to matching profiles |
| `TaskComplete` / `Stop` | Calculates duration, sends completion heartbeat to matching profiles |

Heartbeats are sent to `POST /api/heartbeat` with source `"codex"`. Multiple profiles are dispatched concurrently.

## Skills

### quarryfi-status

Check your tracking status from within Codex:

> "Check my quarryFi R&D tracking status"

Shows all configured profiles, matched projects, seat-scoped tracking stats from QuarryFi, and audit log summary.

### quarryfi-update

Update the plugin to the latest version without leaving Codex:

> "Update quarryFi plugin"

Pulls the latest changes from GitHub, shows what changed, and reminds you to restart the Codex App. No need to open a terminal.

## Updating

There's no auto-update mechanism in the Codex plugin system yet for local personal plugins. To update:

**From inside Codex** (easiest): just ask "Update quarryFi plugin" — the `quarryfi-update` skill handles it.

**From a terminal**:
```bash
cd ~/plugins/quarryfi-time-tracker
git fetch origin
git pull origin main
```

After either method, restart the Codex App to load the new version.

If you installed the plugin from a repo-local `plugins/quarryfi-time-tracker` folder instead of `~/plugins`, update that clone instead.

## Plugin Structure

```
codex-plugin/
├── .codex-plugin/
│   └── plugin.json          # Plugin manifest (Codex spec)
├── hooks/
│   └── track-session.sh     # Lifecycle event handler (multi-profile)
├── skills/
│   ├── quarryfi-status/
│   │   └── SKILL.md          # Status check skill
│   └── quarryfi-update/
│       └── SKILL.md          # Self-update skill
├── setup.sh                  # Interactive profile setup
└── README.md
```

## Compatibility Note

Codex's plugin system launched in March 2026 and is actively evolving. The hook system in this plugin follows the documented lifecycle events. If Codex updates its plugin API, this plugin may need updates — check the [Codex plugin docs](https://developers.openai.com/codex/plugins/build) for the latest spec.

## License

MIT
