#!/usr/bin/env node
/**
 * Fails when a change modifies, renames or deletes a migration that already exists on the base ref.
 * Migrations are append-only: databases that applied a file never run it again, so a change to it
 * would never reach them. Put every schema change in a new file instead.
 *
 *   node scripts/check-migrations.mjs [--base <git ref>]   (default: origin/develop)
 */

import { execFileSync } from 'node:child_process';

const i = process.argv.indexOf('--base');
const base = i >= 0 ? process.argv[i + 1] : 'origin/develop';

let out = '';
try {
  out = execFileSync('git', ['diff', '--name-status', '--find-renames', `${base}...HEAD`, '--', 'supabase/migrations'], { encoding: 'utf-8' });
} catch (err) {
  console.error(`[check-migrations] git diff against ${base} failed: ${err instanceof Error ? err.message : err}`);
  process.exit(1);
}

const offending = out.split('\n').filter(Boolean).filter((line) => !line.startsWith('A\t'));
if (offending.length > 0) {
  console.error('[check-migrations] Released migrations must not change. Add a new migration file instead:');
  for (const line of offending) console.error(`  ${line}`);
  process.exit(1);
}
const added = out.split('\n').filter((l) => l.startsWith('A\t')).length;
console.log(`[check-migrations] OK (${added} new migration file(s), none changed)`);
