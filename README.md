# quarryFi Codex Plugin

R&D time tracking for [OpenAI Codex](https://openai.com/codex). Automatically tracks coding sessions in Codex CLI and Codex App, sending heartbeats to your quarryFi account for tax credit documentation.

Supports **multiple company profiles** with project-to-key routing — freelancers and consultants can track R&D time for different clients from a single config file.

## Install

### From the Codex App

1. Open the **Plugin Directory** (sidebar or settings)
2. Switch the marketplace source to **Personal Plugins** (if you've registered the plugin locally — see below) or search for **quarryfi**
3. Find **quarryFi Time Tracker** and click **Add to Codex**
4. If prompted to authenticate, enter your quarryFi API key (get one from your [dashboard](https://quarryfi.com/dashboard))
5. Fully restart the Codex App or start a new Codex CLI session so the installed version is loaded
6. Review and trust the four quarryFi lifecycle hooks when prompted; in Codex CLI, use `/hooks` if the prompt was dismissed
7. Ask Codex to "Check my quarryFi R&D tracking status" and confirm Codex reports `receiving`

You can enable/disable the plugin at any time from the plugin directory. Codex stores your preference in `~/.codex/config.toml`.
Installing from Personal Plugins does not mean Codex will auto-pull future GitHub changes. If the plugin lives in a local clone, that local clone still needs to be updated.
After a local update, fully restart Codex and start a new session so the fresh hook code and skills actually load.

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
- Manifest declares `"hooks": "./hooks.json"` so Codex registers lifecycle tracking
- A marketplace file includes an entry pointing to the plugin folder

For development or QA of the hook itself, run the local regression check:

```bash
cd ~/plugins/quarryfi-time-tracker
bash -n hooks/track-session.sh
node tests/hook-regression.mjs
```

The regression test uses a temporary `~/.quarryfi/config.json` and a local mock heartbeat server. It verifies that Codex hook events send source `"codex"` payloads to all matching profiles with plugin version, runtime channel, hook mode, and install revision diagnostics. GitHub Actions runs the same check on pushes and pull requests.

## Configuration

This plugin shares `~/.quarryfi/config.json` with the Claude Code plugin. If you use both tools, you only need to configure once.

### Quick Setup

```bash
curl -fsSL https://raw.githubusercontent.com/quarryFi/codex-plugin/main/setup.sh | bash
```

The setup wizard walks you through creating profiles interactively. You'll need your API key from your [quarryFi dashboard](https://quarryfi.com/dashboard).

### Config Format

```json
{
  "profiles": [
    {
      "name": "Acme Corp",
      "api_key": "qf_...",
      "api_url": "https://quarryfi.com",
      "projects": ["/Users/me/work/acme-api", "/Users/me/work/acme-frontend"],
      "codex_default_project": "/Users/me/work/acme-api"
    },
    {
      "name": "Personal",
      "api_key": "qf_...",
      "api_url": "https://quarryfi.com",
      "projects": []
    }
  ]
}
```

Each profile maps an API key to specific project directories. When a hook fires, the script matches the current working directory against profiles and sends heartbeats to all matching endpoints.

The plugin accepts both `"projects"` and `"project_dirs"` arrays so it can share configuration with the Claude Code tracker. For Codex Desktop sessions that report a display-name workspace instead of a real project path, set `"codex_default_project"` on a single-company profile. The hook will use that path for project metadata and routing when the reported Codex cwd does not match any configured project.

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
      "api_url": "https://quarryfi.com",
      "projects": ["/Users/me/clients/acme"]
    },
    {
      "name": "Beta Inc",
      "api_key": "qf_beta_key_here",
      "api_url": "https://quarryfi.com",
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
  "api_url": "https://quarryfi.com"
}
```

When detected, it's treated as one profile that matches all projects. Running `setup.sh` will offer to migrate it to the multi-profile format.

## What It Tracks

- **Session duration** — start and end of each Codex task/session
- **Project name** — derived from your working directory
- **Editor type** — Codex CLI or Codex App
- **Branch** — current git branch
- **Language** — best-effort detection from project files
- **Runtime diagnostics** — plugin version, runtime channel, hook mode, and install revision so QuarryFi can tell a stale install from a healthy one
- **Update cues** — QuarryFi can return a non-blocking version notice after a successful heartbeat; the hook shows it once per release and automatically removes local notice markers after 30 days

### Audit Log

Every heartbeat is appended to `~/.quarryfi/audit.log` as one JSON line per event:

```json
{"ts":"2026-04-08T12:00:00Z","profile":"Acme Corp","api_url":"https://...","http_status":"200","payload":{...}}
```

- Capped at 1MB (older entries are automatically rotated out)
- Fire-and-forget — audit logging never blocks or errors the hook
- Useful for debugging and verifying heartbeats are being sent

### Privacy

- Only project-level metadata is sent (project name, branch, duration, Git HEAD, hashed repository identity, changed-file count, and coarse activity category) plus minimal runtime diagnostics (plugin version, runtime channel, hook mode, install revision)
- Source code, diffs, prompts, commands, command output, raw repository URLs, filenames, local paths, and AI responses are never transmitted
- Data goes only to the API URL configured in each profile
- All tracking runs silently — errors never interrupt your workflow
- The local audit log stays on your machine and is never transmitted

## How It Works

The plugin hooks into Codex lifecycle events and keeps a 60-second timer alive while the session is active:

| Event | Action |
|-------|--------|
| `SessionStart` | Sends a session-start heartbeat and starts the timer |
| `PostToolUse` / `UserPromptSubmit` | Flushes recent activity without double-counting |
| `Stop` | Sends the final heartbeat and clears timer state |

Heartbeats are sent to `POST /api/heartbeat` with source `"codex"`. Multiple profiles are dispatched concurrently. The foreground hook waits only for the network sends it started, while the 60-second timer continues separately in the background; this keeps hooks from hanging and being killed before QuarryFi receives the heartbeat.

For stronger evidence reconciliation, each heartbeat can include the current Git commit SHA, a one-way hash of the GitHub `owner/repository` name, a changed-file count, and a coarse activity category. The plugin does not send source code, diffs, prompts, commands, command output, raw repository URLs, filenames, or local paths.

Codex hook trust is hash-based. If the plugin updates its hook file, Codex can show the plugin as installed while skipping the changed hooks until they are reviewed. In Codex CLI, run `/hooks`, review the quarryFi hooks, and trust the updated commands. In Codex App, restart the app after updating the plugin so the current hook registration and trust prompts load into a fresh session.

## Skills

### quarryfi-status

Check your tracking status from within Codex:

> "Check my quarryFi R&D tracking status"

Shows all configured profiles, matched projects, seat-scoped tracking stats from QuarryFi, the local installed plugin version, and whether any hook fired in the current session.

If QuarryFi shows Codex as `stale` while Claude Code is active, update this plugin, restart Codex, review/trust updated hooks if prompted, then run the status check again after a new Codex action. A healthy Codex status should show source `codex`, a recent `lastHeartbeatAt`, and plugin version `0.4.1` or newer.

### quarryfi-update

Update the plugin to the latest version without leaving Codex:

> "Update quarryFi plugin"

Pulls the latest changes from GitHub into the local plugin folder Codex is using, shows what changed, and reminds you to restart the Codex App. No need to open a terminal, but the restart still matters because personal plugins do not hot-reload mid-session.

## Updating

There's no background auto-update mechanism in the Codex plugin system yet for local personal plugins. To update:

**From inside Codex** (easiest): just ask "Update quarryFi plugin" — the `quarryfi-update` skill handles it.

**From a terminal**:
```bash
cd ~/plugins/quarryfi-time-tracker
git fetch origin
git pull origin main
```

After either method, fully quit and restart the Codex App to load the new version. Personal plugin hooks do not hot-reload into already-running Codex sessions.

To confirm the update took effect:

```bash
jq -r '.version' ~/plugins/quarryfi-time-tracker/.codex-plugin/plugin.json
tail -n 20 ~/.quarryfi/audit.log
```

Then ask Codex: "Check my quarryFi R&D tracking status". The dashboard/API should show a recent Codex heartbeat after the next hook event.

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
