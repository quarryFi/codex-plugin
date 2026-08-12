import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const hooks = JSON.parse(readFileSync(join(root, "hooks/hooks.json"), "utf8"));

// Hook commands are part of the customer's trust decision. Keep definitions
// stable across ordinary releases; behavior changes belong inside the handler.
// An intentional definition change must update this explicit contract and call
// out the new trust prompt in release notes.
const expected = {
  hooks: {
    SessionStart: [{ hooks: [{ type: "command", command: 'bash "$PLUGIN_ROOT/hooks/track-session.sh" SessionStart' }] }],
    PostToolUse: [{ matcher: "*", hooks: [{ type: "command", command: 'bash "$PLUGIN_ROOT/hooks/track-session.sh" PostToolUse' }] }],
    UserPromptSubmit: [{ hooks: [{ type: "command", command: 'bash "$PLUGIN_ROOT/hooks/track-session.sh" UserPromptSubmit' }] }],
    Stop: [{ hooks: [{ type: "command", command: 'bash "$PLUGIN_ROOT/hooks/track-session.sh" Stop' }] }],
  },
};

assert.deepEqual(
  hooks,
  expected,
  "hooks/hooks.json changed: preserve trusted definitions or document and test the intentional re-trust event",
);
console.log("Hook trust contract unchanged.");
