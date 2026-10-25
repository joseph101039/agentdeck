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
//   node trust-codex-hooks.mjs [--list] [--needle <substr>]
//
//   --list            show matching hooks and their trust status; change nothing
//   --needle <substr> only hooks whose definition contains this
//                     (default: AgentDeck/bin/agentdeck-hook)
//
// Exits 1 on any RPC error, or if the app-server hasn't answered in 30s.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { delimiter, join } from 'node:path';
import readline from 'node:readline';

const TIMEOUT_MS = 30_000;

function parseArgs(argv) {
  const o = { list: false, needle: 'AgentDeck/bin/agentdeck-hook' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--list') o.list = true;
    else if (a === '--needle' && i + 1 < argv.length) o.needle = argv[++i];
    else if (a.startsWith('--needle=')) o.needle = a.slice('--needle='.length);
    else {
      console.error(`unknown argument: ${a}\nusage: trust-codex-hooks.mjs [--list] [--needle <substr>]`);
      process.exit(2);
    }
  }
  return o;
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
  const child = spawn(findCodex(), ['app-server'], { stdio: ['pipe', 'pipe', 'inherit'] });
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
    const res = await call('hooks/list', { cwds: [process.cwd()] });
    const entries = (res.data || []).flatMap((d) => d.hooks || d.entries || [d]);
    const matching = entries.filter((h) => JSON.stringify(h).includes(opts.needle));
    if (opts.list) {
      if (!matching.length) console.log(`no hooks matching "${opts.needle}"`);
      for (const h of matching) {
        console.log(`${(h.trustStatus || 'unknown').padEnd(10)} ${h.key}  ${describe(h)}`);
      }
      return;
    }
    // `currentHash` is what Codex would store; without one there is
    // nothing to trust (a hook Codex couldn't resolve).
    const targets = matching.filter((h) => h.trustStatus !== 'trusted' && h.currentHash);
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
