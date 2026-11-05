#!/usr/bin/env node
/**
 * Copies the managed supabase files of this repo into a consumer repo checkout.
 *
 *   node scripts/sync-consumer.mjs --target <dir> [--exclude <path,...>] [--version <v>] [--commit <sha>]
 *                                  [--summary <file.json>] [--dry-run]
 *
 * Rules:
 * - Managed files are the files under MANAGED_PATHS in this repo, minus NEVER_MANAGED and the
 *   consumer's excludes. They overwrite the consumer's copy.
 * - Files the consumer has and this repo never shipped (its own functions, migrations, tests in
 *   supabase/tests/local/) are never touched.
 * - A file shipped by an earlier sync and since removed here is deleted from the consumer.
 * - Migrations are append-only: a released migration is never rewritten (scripts/check-migrations.mjs).
 * - <target>/.edge-sync.json records the version, the commit and a hash per managed file, so the next
 *   sync can tell a local edit ("drift") from an upstream change.
 */

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MANIFEST = '.edge-sync.json';

/** Paths this repo owns in every consumer. */
export const MANAGED_PATHS = [
  'supabase/config.toml',
  'supabase/functions',
  'supabase/migrations',
  'supabase/seeds',
  'supabase/tests',
];

/** Never copied, never deleted: per-repo secrets, CLI state and consumer-only tests. */
const NEVER_MANAGED = [/(^|\/)\.npmrc$/, /(^|\/)\.env(\..*)?$/, /^supabase\/\.temp\//, /^supabase\/tests\/local\//, /(^|\/)\.DS_Store$/];

function parseArgs(argv) {
  const opts = { target: '', exclude: [], version: '', commit: '', summary: '', dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => argv[++i] ?? '';
    if (arg === '--target') opts.target = value();
    else if (arg === '--exclude') opts.exclude = value().split(',').map((s) => s.trim().replace(/\/+$/, '')).filter(Boolean);
    else if (arg === '--version') opts.version = value();
    else if (arg === '--commit') opts.commit = value();
    else if (arg === '--summary') opts.summary = value();
    else if (arg === '--dry-run') opts.dryRun = true;
    else throw new Error(`Unknown option: ${arg}`);
  }
  if (!opts.target) throw new Error('--target <consumer checkout dir> is required');
  return opts;
}

const toPosix = (p) => p.split(path.sep).join('/');
const sha256 = (file) => createHash('sha256').update(fs.readFileSync(file)).digest('hex');

function walk(base, rel) {
  const abs = path.join(base, rel);
  if (!fs.existsSync(abs)) return [];
  if (fs.statSync(abs).isFile()) return [rel];
  return fs.readdirSync(abs).sort().flatMap((name) => walk(base, path.join(rel, name)));
}

function isExcluded(rel, excludes) {
  return excludes.some((e) => rel === e || rel.startsWith(`${e}/`));
}

function managedFiles(base, excludes) {
  return MANAGED_PATHS
    .flatMap((p) => walk(base, p))
    .map(toPosix)
    .filter((rel) => !NEVER_MANAGED.some((re) => re.test(rel)) && !isExcluded(rel, excludes));
}

function readManifest(target) {
  try {
    return JSON.parse(fs.readFileSync(path.join(target, MANIFEST), 'utf-8'));
  } catch {
    return { files: {} };
  }
}

export function sync(opts) {
  const target = path.resolve(opts.target);
  if (!fs.existsSync(target)) throw new Error(`Target not found: ${target}`);
  const exclude = (opts.exclude ?? []).map((e) => e.trim().replace(/\/+$/, '')).filter(Boolean);
  opts = { ...opts, exclude };
  const previous = readManifest(target);
  const previousFiles = previous.files ?? {};
  const files = managedFiles(ROOT, exclude);
  const summary = { added: [], updated: [], removed: [], drifted: [], unchanged: 0, excluded: exclude };
  const manifestFiles = {};

  for (const rel of files) {
    const src = path.join(ROOT, rel);
    const dst = path.join(target, rel);
    const hash = sha256(src);
    manifestFiles[rel] = hash;
    if (!fs.existsSync(dst)) {
      summary.added.push(rel);
    } else {
      const current = sha256(dst);
      if (current === hash) {
        summary.unchanged += 1;
        continue;
      }
      // Changed since the last sync wrote it: a local edit that this sync replaces.
      if (previousFiles[rel] && current !== previousFiles[rel]) summary.drifted.push(rel);
      summary.updated.push(rel);
    }
    if (!opts.dryRun) {
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      fs.copyFileSync(src, dst);
    }
  }

  // Shipped before, gone upstream now (and not excluded meanwhile): remove from the consumer.
  for (const rel of Object.keys(previousFiles)) {
    if (manifestFiles[rel] || isExcluded(rel, opts.exclude)) continue;
    const dst = path.join(target, rel);
    if (!fs.existsSync(dst)) continue;
    if (rel.startsWith('supabase/migrations/')) continue; // migrations are never deleted
    summary.removed.push(rel);
    if (!opts.dryRun) fs.rmSync(dst);
  }

  if (!opts.dryRun) {
    const manifest = {
      source: 'itflorencefe/backoffice-edge',
      version: opts.version || null,
      commit: opts.commit || null,
      synced_at: new Date().toISOString(),
      excluded: opts.exclude,
      files: manifestFiles,
    };
    fs.writeFileSync(path.join(target, MANIFEST), `${JSON.stringify(manifest, null, 2)}\n`, 'utf-8');
  }
  return summary;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const opts = parseArgs(process.argv.slice(2));
    const summary = sync(opts);
    if (opts.summary) fs.writeFileSync(opts.summary, `${JSON.stringify(summary, null, 2)}\n`, 'utf-8');
    console.log(`[edge-sync] ${opts.dryRun ? 'dry run: ' : ''}added=${summary.added.length} updated=${summary.updated.length} removed=${summary.removed.length} drifted=${summary.drifted.length} unchanged=${summary.unchanged}`);
    for (const rel of summary.drifted) console.log(`[edge-sync] local edit replaced: ${rel}`);
  } catch (err) {
    console.error(`[edge-sync] ${err instanceof Error ? err.message : err}`);
    process.exit(1);
  }
}
