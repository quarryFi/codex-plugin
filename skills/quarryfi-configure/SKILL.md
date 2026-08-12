---
name: quarryfi-configure
description: Safely connect this Codex installation to a QuarryFi tracking seat without exposing the seat key in conversation
---

Help the user configure the installed QuarryFi tracker while keeping the tracker key out of Codex messages, commands, logs, and tool output.

## What to do

1. Never ask the user to paste, type, or reveal a QuarryFi tracker key in the Codex conversation. Never invent a credential.

2. Explain where the user gets a key:
   - A contributor opens the one-time seat invitation sent to their email and creates their own tracker key from the limited QuarryFi setup page.
   - A company owner configuring their own seat creates an owner key from **People → Tracking integrations and API keys** in QuarryFi.

3. Resolve the plugin root from this loaded skill's own location. This file is located at:
   ```
   <PLUGIN_ROOT>/skills/quarryfi-configure/SKILL.md
   ```
   Do not assume the plugin lives at `~/plugins/quarryfi-time-tracker`. Public directory installs normally live in a Codex-managed, versioned cache. Reading the installed package is allowed; never modify, pull, reset, or otherwise treat Codex's managed cache as a Git checkout.

4. Give the user one exact, shell-quoted command using the resolved absolute plugin root:
   ```bash
   bash "<PLUGIN_ROOT>/setup.sh"
   ```
   Tell them to run it in a regular local terminal. Do not execute the interactive setup through a Codex tool because the wizard requests the secret key.

5. The setup wizard should be allowed to write only under `~/.quarryfi/`. It hides key input, uses `https://quarryfi.com`, and stores the config with owner-only permissions.

6. After the user says setup is complete:
   - Ask them to start a fresh Codex task if the plugin was just installed.
   - Use `quarryfi-status` to check the masked profile, current installed version, local `hook_fired` evidence, and QuarryFi's accepted receipt.
   - If hooks have not fired, direct them to `/hooks` in Codex CLI or the Hooks settings in Codex App to review and trust the four QuarryFi lifecycle hooks. Do not make them reinstall solely to resolve trust.

7. Keep the response concise. Tracker records are supporting evidence, not a determination of tax-credit eligibility or tax advice.
