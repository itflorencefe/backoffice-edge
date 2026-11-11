/**
 * Atom legal documents — reference runner (no Supabase).
 *
 * Usage:
 *   npm run help
 *   npm run discover
 *   node run.js getDocumentHtml
 */

const fs = require('fs');
const path = require('path');

const {
  AtomLegalClient,
  AtomLegalError,
  AtomLegalAuthError,
} = require('./atomLegalClient');
const { JsonApiHttpError } = require('@digitalvirgo/atom-api');

const ACTION_REGISTRY = {
  getProduct: {
    group: 'catalog',
    summary: 'Fetch the Atom product with optional relationship includes',
    config: ['getProduct.atom_product_id'],
    optional: ['getProduct.include', 'getProduct.outFile'],
  },
  getPacks: {
    group: 'catalog',
    summary: 'Fetch packs with their offers, expiry, prices, currencies and providers',
    config: ['getPacks.atom_product_id'],
    optional: ['getPacks.outFile'],
  },
  login: {
    group: 'auth',
    summary: 'Basic auth → access_token (prints token prefix only)',
    config: [],
    optional: [],
  },
  discover: {
    group: 'legal',
    summary: 'List legal document formats and languages for an Atom product',
    config: ['discover.atom_product_id', 'discover.language'],
    optional: [],
  },
  getDocumentHtml: {
    group: 'legal',
    summary: 'Fetch HTML for one legal document format',
    config: [
      'getDocumentHtml.atom_product_id',
      'getDocumentHtml.language',
      'getDocumentHtml.document_format',
    ],
    optional: ['getDocumentHtml.date', 'getDocumentHtml.outFile'],
  },
  getProductSkus: {
    group: 'catalog',
    summary:
      'List pack-linked SKUs for a product on one platform (e.g. appstore, playstore)',
    config: ['getProductSkus.atom_product_id', 'getProductSkus.platform'],
    optional: [],
  },
};

const VALID_ACTIONS = Object.keys(ACTION_REGISTRY);

const GROUP_LABELS = {
  auth: 'Authentication',
  legal: 'Legal documents',
  catalog: 'Product catalog',
};

function configHint(entry) {
  if (!entry.config || entry.config.length === 0) return '—';
  return entry.config.join(', ');
}

function getNested(obj, dottedKey) {
  const parts = dottedKey.split('.');
  let cur = obj;
  for (const p of parts) {
    if (cur == null || typeof cur !== 'object') return undefined;
    cur = cur[p];
  }
  return cur;
}

function requireConfig(cfg, keys) {
  for (const key of keys) {
    const v = getNested(cfg, key);
    if (v === null || v === undefined || v === '') {
      throw new Error(`Missing required field "${key}" in config.json`);
    }
  }
}

/** Edge-aligned names; legacy camelCase keys still accepted in config.json */
function discoverParams(cfg) {
  const section = cfg.discover ?? {};
  const atom_product_id =
    section.atom_product_id ?? section.atomProductId;
  const language = section.language;
  return { atom_product_id, language };
}

function getDocumentHtmlParams(cfg) {
  const section = cfg.getDocumentHtml ?? {};
  const atom_product_id =
    section.atom_product_id ?? section.atomProductId;
  const language = section.language;
  const document_format =
    section.document_format ?? section.format ?? section.document_slug;
  const { date, outFile } = section;
  return { atom_product_id, language, document_format, date, outFile };
}

function getProductSkusParams(cfg) {
  const section = cfg.getProductSkus ?? {};
  const atom_product_id =
    section.atom_product_id ?? section.atomProductId;
  const platform = section.platform;
  return { atom_product_id, platform };
}

function findSimilarActions(name) {
  const lower = name.toLowerCase();
  return VALID_ACTIONS.filter(
    (a) =>
      a.toLowerCase().includes(lower) ||
      lower.includes(a.toLowerCase()) ||
      a.toLowerCase().startsWith(lower.slice(0, 3)),
  ).slice(0, 5);
}

function printHelpSummary() {
  console.log('Atom legal documents — reference runner\n');
  console.log('Usage:');
  console.log('  npm run <action>          run one call using config.json');
  console.log('  npm run help              this summary');
  console.log('  npm run help -- <action>  detail for one action\n');

  for (const [group, label] of Object.entries(GROUP_LABELS)) {
    console.log(`${label}:`);
    for (const name of VALID_ACTIONS) {
      const entry = ACTION_REGISTRY[name];
      if (entry.group !== group) continue;
      console.log(
        `  ${name.padEnd(20)} ${configHint(entry).slice(0, 50)}`,
      );
    }
    console.log('');
  }

  console.log(
    `${VALID_ACTIONS.length} actions. Copy config.example.json → config.json.`,
  );
}

function printHelpDetail(name) {
  const entry = ACTION_REGISTRY[name];
  console.log(`Action:  ${name}`);
  console.log(`Summary: ${entry.summary}`);
  console.log('\nRequired config:');
  if (entry.config.length === 0) {
    console.log('  staging|production credentials (user, sdkAccessKey, baseUrl)');
  } else {
    for (const key of entry.config) console.log(`  ${key}`);
  }
  if (entry.optional.length > 0) {
    console.log('\nOptional config:');
    for (const key of entry.optional) console.log(`  ${key}`);
  }
}

function isHelpArg(arg) {
  return arg === 'help' || arg === '--help' || arg === '-h';
}

function handleHelp() {
  const arg = process.argv[2];
  const topic = process.argv[3];

  if (!isHelpArg(arg) && arg !== 'help') return false;

  if (arg === 'help' && topic) {
    if (!ACTION_REGISTRY[topic]) {
      const similar = findSimilarActions(topic);
      console.error(`Unknown action "${topic}".`);
      if (similar.length) {
        console.error(`Did you mean: ${similar.join(', ')}?`);
      }
      process.exit(1);
    }
    printHelpDetail(topic);
    return true;
  }

  printHelpSummary();
  return true;
}

function loadConfig() {
  const configPath = path.join(__dirname, 'config.json');
  if (!fs.existsSync(configPath)) {
    throw new Error(
      `config.json not found. Copy config.example.json to config.json and fill credentials.`,
    );
  }
  let cfg;
  try {
    cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch (err) {
    throw new Error(`config.json is not valid JSON: ${err.message}`);
  }
  if (!cfg.environment) {
    throw new Error('config.environment must be "staging" or "production"');
  }
  const envBlock =
    cfg.environment === 'production' ? cfg.production : cfg.staging;
  const baseUrl = envBlock?.baseUrl ?? '';
  if (baseUrl.includes('example.com')) {
    throw new Error(
      `staging/production baseUrl is still a placeholder (${baseUrl}). ` +
        'Use the real Atom API host (e.g. https://staging.atom.digitalvirgo.com).',
    );
  }
  return cfg;
}

function resolveAction(cfg) {
  const fromCli = process.argv[2];
  const action = fromCli || cfg.action;
  if (!action) {
    throw new Error(
      'No action specified. Set config.action or pass one as a CLI arg.',
    );
  }
  if (!VALID_ACTIONS.includes(action)) {
    const similar = findSimilarActions(action);
    let msg = `Invalid action "${action}". Run "npm run help".`;
    if (similar.length) msg += ` Did you mean: ${similar.join(', ')}?`;
    throw new Error(msg);
  }
  return action;
}

function printHeader(label, detail) {
  console.log('────────────────────────────────────────────────────────');
  console.log(`→ ${label}`);
  if (detail !== undefined) console.log(`  ${detail}`);
  console.log('────────────────────────────────────────────────────────');
}

async function runLogin(client) {
  printHeader('AtomLegalClient.login()');
  const token = await client.login();
  console.log(JSON.stringify({ ok: true, tokenPrefix: token.slice(0, 12) + '…' }, null, 2));
}

async function runDiscover(client, cfg) {
  const { atom_product_id, language } = discoverParams(cfg);
  if (atom_product_id == null || atom_product_id === '') {
    throw new Error(
      'Missing required field "discover.atom_product_id" in config.json',
    );
  }
  if (!language) {
    throw new Error('Missing required field "discover.language" in config.json');
  }
  printHeader('discoverDocuments', { atom_product_id, language });
  const res = await client.discoverDocuments(atom_product_id, language);
  console.log(JSON.stringify(res, null, 2));
}

async function runGetProductSkus(client, cfg) {
  const { atom_product_id, platform } = getProductSkusParams(cfg);
  if (atom_product_id == null || atom_product_id === '') {
    throw new Error(
      'Missing required field "getProductSkus.atom_product_id" in config.json',
    );
  }
  if (platform == null || String(platform).trim() === '') {
    throw new Error(
      'Missing required field "getProductSkus.platform" in config.json',
    );
  }
  printHeader('getProductSkus', { atom_product_id, platform });
  const res = await client.getProductSkus(atom_product_id, platform);
  console.log(JSON.stringify(res, null, 2));
}

async function runGetProduct(client, cfg) {
  requireConfig(cfg, ['getProduct.atom_product_id']);
  const { atom_product_id, include, outFile } = cfg.getProduct;
  const product = await client.getProduct(atom_product_id, include);
  if (outFile && String(outFile).trim()) {
    const outPath = path.resolve(String(outFile));
    fs.writeFileSync(outPath, JSON.stringify(product, null, 2) + '\n', 'utf8');
    console.log(JSON.stringify({ ok: true, outFile: outPath }, null, 2));
  } else {
    console.log(JSON.stringify({ ok: true, product }, null, 2));
  }
}

async function runGetPacks(client, cfg) {
  requireConfig(cfg, ['getPacks.atom_product_id']);
  const { atom_product_id, outFile } = cfg.getPacks;
  const result = await client.getPacks(atom_product_id);
  if (outFile && String(outFile).trim()) {
    const outPath = path.resolve(String(outFile));
    fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + '\n', 'utf8');
    console.log(JSON.stringify({ ok: true, outFile: outPath }, null, 2));
  } else {
    console.log(JSON.stringify({ ok: true, ...result }, null, 2));
  }
}

async function runGetDocumentHtml(client, cfg) {
  const { atom_product_id, language, document_format, date, outFile } =
    getDocumentHtmlParams(cfg);
  if (atom_product_id == null || atom_product_id === '') {
    throw new Error(
      'Missing required field "getDocumentHtml.atom_product_id" in config.json',
    );
  }
  if (!language) {
    throw new Error(
      'Missing required field "getDocumentHtml.language" in config.json',
    );
  }
  if (!document_format) {
    throw new Error(
      'Missing required field "getDocumentHtml.document_format" (or format / document_slug) in config.json',
    );
  }
  printHeader('fetchDocumentHtml', {
    atom_product_id,
    language,
    document_format,
    date: date || '(today)',
  });
  const html = await client.fetchDocumentHtml(
    atom_product_id,
    document_format,
    language,
    date,
  );
  if (outFile && String(outFile).trim()) {
    const outPath = path.resolve(String(outFile));
    fs.writeFileSync(outPath, html, 'utf8');
    console.log(JSON.stringify({ ok: true, bytes: html.length, outFile: outPath }, null, 2));
  } else {
    console.log(html);
  }
}

function reportError(err) {
  if (err instanceof JsonApiHttpError) {
    console.error('\n✖ Atom JSON:API error');
    console.error(`  status  : ${err.status}`);
    console.error(`  message : ${err.message}`);
    if (err.errors) console.error(JSON.stringify(err.errors, null, 2));
    return;
  }
  if (err instanceof AtomLegalAuthError) {
    console.error('\n✖ Auth error');
    console.error(`  ${err.message}`);
    console.error('  → Check staging/production user and sdkAccessKey in config.json');
    return;
  }
  if (err instanceof AtomLegalError) {
    console.error('\n✖ Atom legal error');
    console.error(`  ${err.message}`);
    return;
  }
  if (err?.message?.startsWith('Missing required field')) {
    console.error(`\n✖ Config error: ${err.message}`);
    return;
  }
  console.error(`\n✖ ${err.message}`);
  if (err.stack) console.error(err.stack);
}

async function main() {
  if (handleHelp()) return;

  const cfg = loadConfig();
  const action = resolveAction(cfg);
  const env = cfg.environment;

  console.log('Atom legal documents — reference runner');
  console.log(`  environment : ${env}`);
  console.log(`  action      : ${action}`);
  console.log('');

  const client = new AtomLegalClient({
    environment: env,
    staging: cfg.staging,
    production: cfg.production,
  });

  switch (action) {
    case 'getProductSkus':
      await runGetProductSkus(client, cfg);
      break;
    case 'getProduct':
      await runGetProduct(client, cfg);
      break;
    case 'getPacks':
      await runGetPacks(client, cfg);
      break;
    case 'login':
      await runLogin(client);
      break;
    case 'discover':
      await runDiscover(client, cfg);
      break;
    case 'getDocumentHtml':
      await runGetDocumentHtml(client, cfg);
      break;
  }
}

main().catch((err) => {
  reportError(err);
  process.exit(1);
});
