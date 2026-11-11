#!/usr/bin/env node
/**
 * Local Supabase stack running this repo's working tree, for a consumer (e.g. the starter) to use
 * before any pull request or sync.
 *
 *   node scripts/local-dev.mjs start                 Start the stack and apply new migrations
 *   node scripts/local-dev.mjs migrate               Apply migrations not yet applied (keeps data)
 *   node scripts/local-dev.mjs reset                 Recreate the database from migrations + seeds (deletes local data)
 *   node scripts/local-dev.mjs npmrc --from <file>   Copy an .npmrc into the functions with private npm packages
 *   node scripts/local-dev.mjs functions             Serve the edge functions (hot reload, Ctrl+C to stop)
 *   node scripts/local-dev.mjs consumer --target <dir>  Write <dir>/.env.edge.local pointing at the local stack
 *   node scripts/local-dev.mjs dev --target <dir> [--port 5174] [--no-functions]
 *                                                   All in one: start + migrate, .npmrc copied from <dir> when
 *                                                   missing, functions served, <dir>/.env.edge.local written and
 *                                                   the consumer's Vite dev server run on it (`vite --mode edge`,
 *                                                   its own port, so its own browser storage). Ctrl+C stops the
 *                                                   functions and Vite; the stack keeps running (`stop`).
 *   node scripts/local-dev.mjs status                URLs of the running stack (no keys)
 *   node scripts/local-dev.mjs stop                  Stop the stack (data is kept)
 *
 * Function secrets (Atom, Pulsar, ...) are read from supabase/functions/.env when it exists (gitignored).
 * Keys are never printed.
 */

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FUNCTIONS_DIR = path.join(ROOT, 'supabase/functions');
const FUNCTIONS_ENV = path.join(FUNCTIONS_DIR, '.env');
const CONSUMER_ENV_FILE = '.env.edge.local';
const PRIVATE_SCOPE = '@digitalvirgo/';

function supabase(args, { capture = false } = {}) {
  const res = spawnSync('supabase', args, {
    cwd: ROOT,
    stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
    encoding: 'utf-8',
  });
  if (res.error) throw new Error(`supabase CLI not runnable: ${res.error.message}`);
  if (res.status !== 0) {
    const err = new Error(`supabase ${args.join(' ')} failed (exit ${res.status})`);
    err.stdout = res.stdout ?? '';
    throw err;
  }
  return res.stdout ?? '';
}

/** Drops the lines that carry keys, secrets or passwords (output of `supabase start`). */
function withoutSecrets(text) {
  return text
    .split('\n')
    .filter((line) => !/key|secret|jwt|token|password/i.test(line))
    .join('\n');
}

/** `supabase status -o env` as an object (contains keys: never print it). */
function statusEnv() {
  const out = supabase(['status', '-o', 'env'], { capture: true });
  const env = {};
  for (const line of out.split('\n')) {
    const m = line.match(/^([A-Z_]+)="?(.*?)"?$/);
    if (m) env[m[1]] = m[2];
  }
  if (!env.API_URL) throw new Error('Local stack not running: run `npm run local:start` first.');
  return env;
}

function printStatus() {
  const env = statusEnv();
  console.log(`API       ${env.API_URL}`);
  console.log(`Functions ${env.API_URL}/functions/v1/<name>`);
  if (env.STUDIO_URL) console.log(`Studio    ${env.STUDIO_URL}`);
  if (env.INBUCKET_URL || env.MAILPIT_URL) console.log(`Mail      ${env.MAILPIT_URL || env.INBUCKET_URL}`);
  if (env.DB_URL) console.log(`Database  ${env.DB_URL.replace(/\/\/([^:]+):[^@]*@/, '//$1:***@')}`);
}

/** Functions whose deno.json imports a private npm package (they need an .npmrc next to it). */
function privateFunctions() {
  return fs
    .readdirSync(FUNCTIONS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .filter((name) => {
      const denoJson = path.join(FUNCTIONS_DIR, name, 'deno.json');
      return fs.existsSync(denoJson) && fs.readFileSync(denoJson, 'utf-8').includes(PRIVATE_SCOPE);
    });
}

function copyNpmrc(from) {
  if (!from) throw new Error('--from <path to an .npmrc with the @digitalvirgo token> is required');
  const source = path.resolve(from);
  if (!fs.existsSync(source)) throw new Error(`${source} not found`);
  for (const name of privateFunctions()) {
    fs.copyFileSync(source, path.join(FUNCTIONS_DIR, name, '.npmrc'));
    console.log(`.npmrc → supabase/functions/${name}/ (gitignored)`);
  }
}

function serveFunctions() {
  const missing = privateFunctions().filter((name) => !fs.existsSync(path.join(FUNCTIONS_DIR, name, '.npmrc')));
  if (missing.length > 0) {
    console.warn(`Without .npmrc (they will fail to load): ${missing.join(', ')}. Run: npm run local:npmrc -- --from <file>`);
  }
  const args = ['functions', 'serve'];
  if (fs.existsSync(FUNCTIONS_ENV)) args.push('--env-file', FUNCTIONS_ENV);
  else console.warn('No supabase/functions/.env: functions needing secrets (Atom, Pulsar, ...) will answer with errors.');
  supabase(args);
}

/** Sets the given keys in an env file, keeping the other lines. */
function writeEnvFile(file, values) {
  const lines = fs.existsSync(file) ? fs.readFileSync(file, 'utf-8').split('\n') : [
    '# Written by backoffice-edge scripts/local-dev.mjs: the local Supabase stack (gitignored).',
    '# Used by `npm run dev:edge` (vite --mode edge).',
  ];
  const seen = new Set();
  const out = lines.map((line) => {
    const key = line.match(/^#?\s*([A-Z_]+)=/)?.[1];
    if (!key || !(key in values)) return line;
    seen.add(key);
    return `${key}=${values[key]}`;
  });
  for (const [key, value] of Object.entries(values)) if (!seen.has(key)) out.push(`${key}=${value}`);
  fs.writeFileSync(file, out.join('\n').replace(/\n*$/, '\n'), { mode: 0o600 });
}

function writeConsumerEnv(target) {
  if (!target) throw new Error('--target <consumer checkout dir> is required');
  const dir = path.resolve(target);
  if (!fs.existsSync(path.join(dir, 'package.json'))) throw new Error(`${dir} is not a repo checkout`);
  const env = statusEnv();
  const anon = env.ANON_KEY || env.PUBLISHABLE_KEY;
  const service = env.SERVICE_ROLE_KEY || env.SECRET_KEY;
  if (!anon || !service) throw new Error('`supabase status` did not return the API keys');
  writeEnvFile(path.join(dir, CONSUMER_ENV_FILE), {
    VITE_SUPABASE_URL: env.API_URL,
    VITE_SUPABASE_ANON_KEY: anon,
    SUPABASE_SERVICE_ROLE_KEY: service,
  });
  console.log(`${path.join(dir, CONSUMER_ENV_FILE)} → ${env.API_URL} (keys written, not shown)`);
}

/**
 * Containers inherit the host DNS search domains. Some home routers answer 127.0.0.1 for any name
 * under their domain, and the API gateway (Kong) then sends every request to itself: 502 everywhere.
 */
function dnsSearchHint() {
  let search = '';
  try {
    search = fs.readFileSync('/etc/resolv.conf', 'utf-8').match(/^search\s+(.+)$/m)?.[1] ?? '';
  } catch {
    return;
  }
  if (!search) return;
  console.error(`
Health check failed and the host has DNS search domains (${search}).
If the gateway logs show upstream 127.0.0.1 (docker logs supabase_kong_<project_id>), the router resolves
container names under those domains to 127.0.0.1. Remove the search domains from Docker containers:
  /etc/docker/daemon.json  →  { "dns-search": ["."] }
  sudo systemctl restart docker && npm run local:start
`);
}

/** project_id of supabase/config.toml (names the local containers). */
function projectId() {
  const toml = fs.readFileSync(path.join(ROOT, 'supabase/config.toml'), 'utf-8');
  return toml.match(/^project_id\s*=\s*"([^"]+)"/m)?.[1] ?? '';
}

/** Stops the container of `functions serve` when the CLI left it running. */
function stopFunctionsContainer() {
  const name = `supabase_edge_runtime_${projectId()}`;
  const ps = spawnSync('docker', ['ps', '-q', '--filter', `name=^${name}$`], { encoding: 'utf-8' });
  if (ps.stdout?.trim()) spawnSync('docker', ['stop', name], { stdio: 'ignore' });
}

/** Starts the stack (no-op when running) and applies the new migrations. */
function startStack() {
  // Functions are served by `functions` / `dev` (hot reload, secrets from supabase/functions/.env).
  // stdout of `supabase start` ends with the API keys: captured, never printed as is.
  try {
    supabase(['start', '-x', 'edge-runtime'], { capture: true });
  } catch (err) {
    if (err.stdout) console.error(withoutSecrets(err.stdout).trim().split('\n').slice(-40).join('\n'));
    dnsSearchHint();
    throw err;
  }
  supabase(['migration', 'up', '--local']);
  printStatus();
}

/** Copies <dir>/.npmrc into the private functions that have none (the consumer has the token). */
function npmrcFromConsumer(dir) {
  const missing = privateFunctions().filter((name) => !fs.existsSync(path.join(FUNCTIONS_DIR, name, '.npmrc')));
  const source = path.join(dir, '.npmrc');
  if (missing.length > 0 && fs.existsSync(source)) copyNpmrc(source);
}

/** Runs a child process with its output lines prefixed (lines with keys dropped); onLine sees every line. */
function startChild(label, command, args, cwd, onLine = () => {}) {
  // Own process group: a signal to the group also reaches grandchildren (npx → vite).
  const child = spawn(command, args, { cwd, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  for (const stream of [child.stdout, child.stderr]) {
    let rest = '';
    stream.setEncoding('utf-8');
    stream.on('data', (chunk) => {
      const lines = (rest + chunk).split('\n');
      rest = lines.pop() ?? '';
      for (const line of lines) {
        onLine(line);
        if (!/key|secret|token|password/i.test(line)) process.stdout.write(`[${label}] ${line}\n`);
      }
    });
  }
  return child;
}

/** Everything for a local session: stack, functions and the consumer's dev server. */
async function runDev(target, port, withFunctions) {
  if (!target) throw new Error('--target <consumer checkout dir> is required');
  const dir = path.resolve(target);
  startStack();
  writeConsumerEnv(target);

  const children = [];
  let stopping = false;
  const running = (c) => c.exitCode === null && c.signalCode === null;
  const stopAll = (code) => {
    if (stopping) return;
    stopping = true;
    for (const child of children) {
      if (!running(child)) continue;
      try {
        process.kill(-child.pid, 'SIGINT');
      } catch {
        child.kill('SIGINT');
      }
    }
    const done = () => {
      stopFunctionsContainer();
      console.log('Stopped functions and dev server. The stack keeps running: npm run local:stop to stop it.');
      process.exit(code);
    };
    setTimeout(done, 10_000).unref();
    Promise.all(children.filter(running).map((c) => new Promise((r) => c.on('exit', r)))).then(done);
  };
  process.on('SIGINT', () => stopAll(0));
  process.on('SIGTERM', () => stopAll(0));

  if (withFunctions) {
    npmrcFromConsumer(dir);
    const args = ['functions', 'serve'];
    if (fs.existsSync(FUNCTIONS_ENV)) args.push('--env-file', FUNCTIONS_ENV);
    else console.warn('No supabase/functions/.env: functions needing secrets (Atom, Pulsar, ...) will answer with errors.');
    let ready = () => {};
    const served = new Promise((resolve) => (ready = resolve));
    const functions = startChild('functions', 'supabase', args, ROOT, (line) => {
      if (/Serving functions on/.test(line)) ready();
    });
    children.push(functions);
    functions.on('exit', (code) => {
      if (!stopping) console.error(`Functions server exited (${code}).`);
      ready();
      stopAll(code ?? 1);
    });
    // The first run pulls the runtime image: wait for it before opening the app.
    await Promise.race([served, new Promise((r) => setTimeout(r, 180_000))]);
    if (stopping) return;
  }

  console.log(`Starting ${path.basename(dir)} on http://localhost:${port} against the local stack...`);
  const vite = startChild('app', 'npx', ['vite', '--mode', 'edge', '--port', port, '--strictPort'], dir);
  children.push(vite);
  vite.on('exit', (code) => stopAll(code ?? 0));
}

function option(argv, name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] ?? '' : '';
}

function main(argv) {
  const [command] = argv;
  switch (command) {
    case 'start':
      startStack();
      return;
    case 'migrate':
      supabase(['migration', 'up', '--local']);
      return;
    case 'reset':
      supabase(['db', 'reset', '--local']);
      return;
    case 'npmrc':
      copyNpmrc(option(argv, '--from'));
      return;
    case 'functions':
      serveFunctions();
      return;
    case 'consumer':
      writeConsumerEnv(option(argv, '--target'));
      return;
    case 'dev':
      return runDev(option(argv, '--target'), option(argv, '--port') || '5174', !argv.includes('--no-functions'));
    case 'status':
      printStatus();
      return;
    case 'stop':
      supabase(['stop']);
      return;
    default:
      console.error('Usage: node scripts/local-dev.mjs start|migrate|reset|npmrc --from <file>|functions|consumer --target <dir>|dev --target <dir> [--port n] [--no-functions]|status|stop');
      process.exit(1);
  }
}

Promise.resolve()
  .then(() => main(process.argv.slice(2)))
  .catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
