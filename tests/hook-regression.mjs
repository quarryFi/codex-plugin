import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const hookPath = join(repoRoot, "hooks", "track-session.sh");
const manifest = JSON.parse(readFileSync(join(repoRoot, ".codex-plugin", "plugin.json"), "utf8"));
const hooksConfig = JSON.parse(readFileSync(join(repoRoot, "hooks.json"), "utf8"));
const tmpHome = mkdtempSync(join(tmpdir(), "quarryfi-codex-hook-"));
const projectRoot = join(tmpHome, "work", "client-a");
const projectDir = join(projectRoot, "app");
const projectDirsRoot = join(tmpHome, "work", "client-b");
const projectDirsDir = join(projectDirsRoot, "app");
const codexFallbackDir = join(tmpHome, "work", "codex-default", "quarryfi");
const pseudoCodexDir = join(tmpHome, "New Flow");
const configDir = join(tmpHome, ".quarryfi");
const received = [];

assertSupportedCodexHooks();
assertProductionHostname();

mkdirSync(projectDir, { recursive: true });
mkdirSync(projectDirsDir, { recursive: true });
mkdirSync(codexFallbackDir, { recursive: true });
mkdirSync(pseudoCodexDir, { recursive: true });
mkdirSync(configDir, { recursive: true });
writeFileSync(join(projectDir, "package.json"), "{}\n");
writeFileSync(join(projectDirsDir, "package.json"), "{}\n");
writeFileSync(join(codexFallbackDir, "package.json"), "{}\n");

const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => {
    body += chunk;
  });
  request.on("end", () => {
    received.push({
      method: request.method,
      url: request.url,
      authorization: request.headers.authorization,
      body: JSON.parse(body),
    });
    response.writeHead(204).end();
  });
});

try {
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  const { port } = server.address();
  const apiUrl = `http://127.0.0.1:${port}`;

  writeFileSync(
    join(configDir, "config.json"),
    JSON.stringify({
      profiles: [
        { name: "Client A", api_key: "qf_client_a", api_url: apiUrl, projects: [projectRoot] },
        { name: "Client B", api_key: "qf_client_b", api_url: apiUrl, project_dirs: [projectDirsRoot] },
        { name: "Catch All", api_key: "qf_catch_all", api_url: apiUrl, projects: [] },
        { name: "Other Client", api_key: "qf_other", api_url: apiUrl, projects: [join(tmpHome, "other")] },
      ],
    }, null, 2)
  );

  const result = await runHook(["UserPromptSubmit", projectDir, "ci-session"]);
  assert.equal(result.code, 0, result.stderr);
  assert.equal(received.length, 2);
  assert.deepEqual(
    received.map((request) => request.authorization).sort(),
    ["Bearer qf_catch_all", "Bearer qf_client_a"]
  );

  for (const request of received) {
    assert.equal(request.method, "POST");
    assert.equal(request.url, "/api/heartbeat");
    assert.equal(request.body.client.plugin_version, manifest.version);
    assert.equal(request.body.client.hook_mode, "event_plus_timer");
    assert.match(request.body.client.runtime_channel, /^codex_/);
    assert.equal(request.body.client.host_app, "codex_app");

    const [heartbeat] = request.body.heartbeats;
    assert.equal(heartbeat.source, "codex");
    assert.equal(heartbeat.event, "heartbeat");
    assert.equal(heartbeat.session_id, "ci-session");
    assert.equal(heartbeat.project_name, "app");
    assert.equal(heartbeat.language, "javascript");
  }

  received.length = 0;
  const projectDirsResult = await runHook(["UserPromptSubmit", projectDirsDir, "ci-project-dirs-session"], projectDirsDir);
  assert.equal(projectDirsResult.code, 0, projectDirsResult.stderr);
  assert.deepEqual(
    received.map((request) => request.authorization).sort(),
    ["Bearer qf_catch_all", "Bearer qf_client_b"]
  );
  assert.equal(received[0].body.heartbeats[0].project_name, "app");

  received.length = 0;
  writeFileSync(
    join(configDir, "config.json"),
    JSON.stringify({
      profiles: [
        {
          name: "Solo Company",
          api_key: "qf_solo",
          api_url: apiUrl,
          projects: [join(tmpHome, "unmatched", "root")],
          codex_default_project: codexFallbackDir,
        },
      ],
    }, null, 2)
  );

  const fallbackResult = await runHook(["UserPromptSubmit", pseudoCodexDir, "ci-fallback-session"], pseudoCodexDir);
  assert.equal(fallbackResult.code, 0, fallbackResult.stderr);
  assert.equal(received.length, 1);
  assert.equal(received[0].authorization, "Bearer qf_solo");
  assert.equal(received[0].body.heartbeats[0].project_name, "quarryfi");
  assert.equal(received[0].body.heartbeats[0].language, "javascript");
} finally {
  stopHookTimers();
  await new Promise((resolveClose) => server.close(resolveClose));
  rmSync(tmpHome, { recursive: true, force: true });
}

function assertSupportedCodexHooks() {
  const supportedEvents = new Set([
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PreCompact",
    "PostCompact",
    "UserPromptSubmit",
    "SubagentStart",
    "SubagentStop",
    "SessionStart",
    "Stop",
  ]);

  for (const eventName of Object.keys(hooksConfig.hooks ?? {})) {
    assert.ok(supportedEvents.has(eventName), `${eventName} is not a supported Codex hook event`);
  }

  const postToolUseGroups = hooksConfig.hooks?.PostToolUse ?? [];
  assert.ok(postToolUseGroups.length > 0, "PostToolUse hook must be registered");
  assert.ok(
    postToolUseGroups.some((group) => group.matcher === "*" || group.matcher === undefined),
    "PostToolUse must match all current Codex tool names"
  );
}

function assertProductionHostname() {
  const retiredHostname = "quarryfi.smashedstudiosllc.workers.dev";
  for (const relativePath of [
    ".codex-plugin/plugin.json",
    "hooks/track-session.sh",
    "setup.sh",
    "skills/quarryfi-status/SKILL.md",
  ]) {
    const contents = readFileSync(join(repoRoot, relativePath), "utf8");
    assert.ok(!contents.includes(retiredHostname), `${relativePath} must not use the retired workers.dev hostname`);
  }
}

function runHook(args, cwd = projectDir) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn("bash", [hookPath, ...args], {
      cwd,
      env: {
        ...process.env,
        HOME: tmpHome,
        CODEX_CLIENT: "app",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      rejectRun(new Error("hook regression timed out"));
    }, 8000);

    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", rejectRun);
    child.on("close", (code) => {
      clearTimeout(timeout);
      resolveRun({ code, stdout, stderr });
    });
  });
}

function stopHookTimers() {
  const auditRoot = join(tmpHome, ".quarryfi");
  try {
    for (const entry of readdirSync(auditRoot)) {
      const pidFile = join(auditRoot, entry, "timer.pid");
      if (!entry.startsWith("session-codex-") || !existsSync(pidFile)) continue;
      const pid = Number(readFileSync(pidFile, "utf8"));
      if (Number.isInteger(pid) && pid > 0) {
        try {
          process.kill(pid, "SIGTERM");
        } catch {
          // Timer may already be gone.
        }
      }
    }
  } catch {
    // Best-effort cleanup only.
  }
}
