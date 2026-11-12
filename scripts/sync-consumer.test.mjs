import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { sync } from './sync-consumer.mjs';

const MIGRATIONS = 'supabase/migrations';

function consumer(files = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'edge-sync-'));
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), content);
  }
  return dir;
}

const read = (dir, rel) => fs.readFileSync(path.join(dir, rel), 'utf-8');
const exists = (dir, rel) => fs.existsSync(path.join(dir, rel));
const manifest = (dir) => JSON.parse(read(dir, '.edge-sync.json'));
const firstMigration = () => `${MIGRATIONS}/${fs.readdirSync(MIGRATIONS).sort()[0]}`;

test('a first sync copies every managed file and writes the manifest', () => {
  const dir = consumer({ 'src/App.tsx': 'ui' });
  const summary = sync({ target: dir, exclude: [], version: '1.0.0', commit: 'abc' });
  assert.ok(summary.added.includes('supabase/config.toml'));
  assert.ok(summary.added.includes('supabase/functions/screen-layout/index.ts'));
  assert.equal(read(dir, 'supabase/functions/screen-layout/index.ts'), read('.', 'supabase/functions/screen-layout/index.ts'));
  assert.equal(read(dir, 'src/App.tsx'), 'ui');
  const m = manifest(dir);
  assert.equal(m.version, '1.0.0');
  assert.equal(m.commit, 'abc');
  assert.ok(m.files['supabase/functions/screen-layout/index.ts']);
});

test('a second sync without changes touches nothing', () => {
  const dir = consumer();
  sync({ target: dir, exclude: [] });
  const again = sync({ target: dir, exclude: [] });
  assert.deepEqual([again.added, again.updated, again.removed, again.drifted], [[], [], [], []]);
  assert.ok(again.unchanged > 0);
});

test('local edits are replaced and reported as drift', () => {
  const dir = consumer();
  sync({ target: dir, exclude: [] });
  fs.writeFileSync(path.join(dir, 'supabase/functions/static-env-proxy/index.ts'), '// edited here');
  const s = sync({ target: dir, exclude: [] });
  assert.deepEqual(s.drifted, ['supabase/functions/static-env-proxy/index.ts']);
  assert.deepEqual(s.updated, ['supabase/functions/static-env-proxy/index.ts']);
  assert.equal(read(dir, 'supabase/functions/static-env-proxy/index.ts'), read('.', 'supabase/functions/static-env-proxy/index.ts'));
});

test('excluded paths, secrets, CLI state and local tests are never touched', () => {
  const dir = consumer({
    'supabase/functions/pulsar/index.ts': '// custom pulsar',
    'supabase/functions/pulsar/.npmrc': 'token',
    'supabase/.temp/project-ref': 'ref',
    'supabase/tests/local/custom_test.ts': '// local',
  });
  const s = sync({ target: dir, exclude: ['supabase/functions/pulsar/'] });
  assert.equal(read(dir, 'supabase/functions/pulsar/index.ts'), '// custom pulsar');
  assert.equal(read(dir, 'supabase/functions/pulsar/.npmrc'), 'token');
  assert.equal(read(dir, 'supabase/.temp/project-ref'), 'ref');
  assert.equal(read(dir, 'supabase/tests/local/custom_test.ts'), '// local');
  assert.ok(!s.added.concat(s.updated).some((f) => f.startsWith('supabase/functions/pulsar/')));
  assert.ok(!Object.keys(manifest(dir).files).some((f) => f.startsWith('supabase/functions/pulsar/')));
});

test('files of the consumer that this repo never shipped are kept', () => {
  const dir = consumer({
    'supabase/functions/only-here/index.ts': '// consumer function',
    [`${MIGRATIONS}/29991231000000_local.sql`]: 'select 1;',
  });
  sync({ target: dir, exclude: [] });
  const s = sync({ target: dir, exclude: [] });
  assert.equal(read(dir, 'supabase/functions/only-here/index.ts'), '// consumer function');
  assert.ok(exists(dir, `${MIGRATIONS}/29991231000000_local.sql`));
  assert.deepEqual(s.removed, []);
});

test('a file removed upstream is deleted, a migration never is', () => {
  const dir = consumer();
  sync({ target: dir, exclude: [] });
  const m = manifest(dir);
  m.files['supabase/functions/gone/index.ts'] = 'x';
  m.files[`${MIGRATIONS}/20000101000000_old.sql`] = 'x';
  fs.writeFileSync(path.join(dir, '.edge-sync.json'), JSON.stringify(m));
  fs.mkdirSync(path.join(dir, 'supabase/functions/gone'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'supabase/functions/gone/index.ts'), 'x');
  fs.writeFileSync(path.join(dir, `${MIGRATIONS}/20000101000000_old.sql`), 'x');
  const s = sync({ target: dir, exclude: [] });
  assert.deepEqual(s.removed, ['supabase/functions/gone/index.ts']);
  assert.ok(!exists(dir, 'supabase/functions/gone/index.ts'));
  assert.ok(exists(dir, `${MIGRATIONS}/20000101000000_old.sql`));
  assert.ok(exists(dir, firstMigration()));
});

test('dry run reports without writing', () => {
  const dir = consumer();
  const s = sync({ target: dir, exclude: [], dryRun: true });
  assert.ok(s.added.length > 0);
  assert.ok(!exists(dir, 'supabase/config.toml'));
  assert.ok(!exists(dir, '.edge-sync.json'));
});
