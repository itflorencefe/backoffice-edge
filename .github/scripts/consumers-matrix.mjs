// Prints the GitHub Actions matrix of consumers.json as `matrix=<json>` (for $GITHUB_OUTPUT).
// Usage: node .github/scripts/consumers-matrix.mjs [only-this-owner/repo]
import fs from 'node:fs';

const only = (process.argv[2] || '').trim();
const { consumers = [] } = JSON.parse(fs.readFileSync('consumers.json', 'utf-8'));
const include = consumers
  .filter((c) => !only || c.repo === only)
  .map((c) => {
    const [owner, name] = c.repo.split('/');
    if (!owner || !name) throw new Error(`Invalid repo "${c.repo}" in consumers.json (expected owner/name)`);
    return {
      repo: c.repo,
      owner,
      name,
      branch: c.branch || 'main',
      exclude: (c.exclude || []).join(','),
      artifact: c.repo.replace('/', '__'),
    };
  });
if (only && include.length === 0) throw new Error(`"${only}" is not registered in consumers.json`);
console.log(`matrix=${JSON.stringify({ include })}`);
