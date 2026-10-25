#!/usr/bin/env node
// Trusts AgentDeck's Codex hooks.
//
// Codex runs a hook only once its exact command has been trusted (a
// `trusted_hash` under `[hooks.state."<file>:<event>:i:j"]`), so freshly
// installed hooks stay silent for `codex exec` and app-server runs until
// someone approves them in the interactive /hooks screen. This asks Codex's
// own app-server to do the same thing over JSON-RPC — Codex computes the
// hashes and writes its config — instead of editing config.toml by hand.
//
//   node trust-codex-hooks.mjs [--list] [--hook <path>]
//
//   --list         show AgentDeck's hooks and their trust status; change nothing
//   --hook <path>  the installed helper (default: ~/Library/Application
//                  Support/AgentDeck/bin/agentdeck-hook)
//
// Only a user-level command hook whose command is exactly the one
// HookInstaller writes (`'<helper>' codex`, or the older double-quoted
// form) is trusted. Anything looser — a substring of the definition, a
// project's .codex hooks — would let any repo get a hook approved just by
// mentioning the path, which is what Codex's trust gate exists to stop.
//
// Exits 1 on any RPC error, when no AgentDeck hook is installed, or if the
// app-server hasn't answered in 30s.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { delimiter, dirname, isAbsolute, join } from 'node:path';
import readline from 'node:readline';

const TIMEOUT_MS = 30_000;

const DEFAULT_HOOK = join(homedir(), 'Library/Application Support/AgentDeck/bin/agentdeck-hook');

function parseArgs(argv) {
  const o = { list: false, hook: DEFAULT_HOOK };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--list') o.list = true;
    else if (a === '--hook' && i + 1 < argv.length) o.hook = argv[++i];
    else if (a.startsWith('--hook=')) o.hook = a.slice('--hook='.length);
    else {
      console.error(`unknown argument: ${a}\nusage: trust-codex-hooks.mjs [--list] [--hook <path>]`);
      process.exit(2);
    }
  }
  if (!isAbsolute(o.hook)) {
    console.error('--hook must be an absolute path');
    process.exit(2);
  }
  return o;
}

// Same quoting as WorkspaceRestore.shellQuote / HookInstaller.command(for:).
const shellQuote = (s) => `'${s.replaceAll("'", "'\\''")}'`;

function isAgentDeckHook(h, hook) {
  const accepted = [`${shellQuote(hook)} codex`];
  if (!/[$`"\\!]/.test(hook)) accepted.push(`"${hook}" codex`);
  return h.source === 'user' && h.handlerType === 'command' && accepted.includes(describe(h));
}

// Launched from a GUI app, PATH is the bare system one; Codex usually lives
// in one of these instead.
function findCodex() {
  if (process.env.CODEX_BIN) return process.env.CODEX_BIN;
  const dirs = [
    ...(process.env.PATH || '').split(delimiter),
    join(homedir(), '.local/bin'),
    '/opt/homebrew/bin',
    '/usr/local/bin',
  ];
  for (const dir of dirs) {
    if (dir && existsSync(join(dir, 'codex'))) return join(dir, 'codex');
  }
  return 'codex';
}

const describe = (h) => h.command ?? h.handler?.command ?? h.hook?.command ?? '';

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  // An npm-installed codex is a `#!/usr/bin/env node` script; from a GUI
  // app's bare PATH that env lookup fails, so put our own node first.
  const env = { ...process.env, PATH: [dirname(process.execPath), process.env.PATH].filter(Boolean).join(delimiter) };
  const child = spawn(findCodex(), ['app-server'], { stdio: ['pipe', 'pipe', 'inherit'], env });
  const timer = setTimeout(() => {
    console.error(`codex app-server did not answer within ${TIMEOUT_MS / 1000}s`);
    child.kill();
    process.exit(1);
  }, TIMEOUT_MS);
  const pending = new Map();
  let nextId = 1;
  const failAll = (err) => {
    for (const { reject } of pending.values()) reject(err);
    pending.clear();
  };
  child.on('error', (e) => failAll(new Error(`couldn't run codex: ${e.message}`)));
  child.on('exit', (code) => failAll(new Error(`codex app-server exited (${code})`)));
  // a write after the child died raises EPIPE here; 'exit' reports it
  child.stdin.on('error', () => {});
  readline.createInterface({ input: child.stdout }).on('line', (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.id == null || !pending.has(msg.id)) return;
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) reject(new Error(JSON.stringify(msg.error)));
    else resolve(msg.result);
  });
  const call = (method, params) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });

  try {
    await call('initialize', {
      clientInfo: { name: 'agentdeck', title: null, version: '1' },
      capabilities: null,
    });
    child.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n');
    // Home, not the caller's cwd: a project's own .codex hooks are never ours.
    const res = await call('hooks/list', { cwds: [homedir()] });
    const entries = (res.data || []).flatMap((d) => d.hooks || d.entries || [d]);
    const matching = entries.filter((h) => isAgentDeckHook(h, opts.hook));
    if (opts.list) {
      if (!matching.length) console.log(`no AgentDeck hooks for ${opts.hook}`);
      for (const h of matching) {
        console.log(`${(h.trustStatus || 'unknown').padEnd(10)} ${h.key}  ${describe(h)}`);
      }
      return;
    }
    if (!matching.length) throw new Error(`no AgentDeck hooks installed in ~/.codex/hooks.json (looked for ${opts.hook})`);
    // `currentHash` is what Codex would store; without one there is
    // nothing to trust (a hook Codex couldn't resolve).
    const unhashed = matching.filter((h) => h.trustStatus !== 'trusted' && !h.currentHash);
    if (unhashed.length) throw new Error(`Codex can't resolve ${unhashed.map((h) => h.key).join(', ')}`);
    const targets = matching.filter((h) => h.trustStatus !== 'trusted');
    if (!targets.length) {
      console.log(`codex hooks: all ${matching.length} AgentDeck hooks already trusted`);
      return;
    }
    const value = Object.fromEntries(targets.map((h) => [h.key, { trusted_hash: h.currentHash }]));
    await call('config/batchWrite', {
      edits: [{ keyPath: 'hooks.state', value, mergeStrategy: 'upsert' }],
      reloadUserConfig: false,
    });
    console.log(`codex hooks: trusted ${targets.length}: ${targets.map((h) => h.key).join(', ')}`);
  } catch (e) {
    console.error(`codex hooks: ${e.message}`);
    process.exitCode = 1;
  } finally {
    clearTimeout(timer);
    child.removeAllListeners('exit');
    child.kill();
  }
}

main();
