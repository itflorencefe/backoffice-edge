// Semantic release (run by .github/workflows/release.yml after develop is merged into main):
// analyzes the Conventional Commits since the last tag, bumps package.json, updates CHANGELOG.md,
// commits on main, tags it (e.g. 1.2.0) and creates the GitHub release.
// Same rules as the starter template, so versions read the same across the back office repos.
module.exports = {
  branches: ['main'],
  tagFormat: '${version}',
  preset: 'conventionalcommits',
  plugins: [
    ['@semantic-release/commit-analyzer', {
      parserOpts: {
        noteKeywords: ['BREAKING CHANGE', 'BREAKING CHANGES', 'BREAKING'],
      },
      releaseRules: [
        { type: 'docs', release: 'patch' },
        { type: 'dep', release: 'patch' },
        { type: 'ci', release: 'patch' },
        { type: 'chore', release: 'patch' },
        { type: 'refactor', release: 'patch' },
        { type: 'chore', scope: 'deps', release: 'patch' },
        { type: 'fix', scope: 'deps', release: 'patch' },
      ],
    }],
    ['@semantic-release/release-notes-generator', {
      presetConfig: {
        types: [
          { type: 'feat', section: 'Features' },
          { type: 'fix', section: 'Bug Fixes' },
          { type: 'refactor', section: 'Refactoring' },
          { type: 'docs', section: 'Documentation' },
          { type: 'dep', section: 'Dependencies' },
          { type: 'ci', section: 'CI' },
          { type: 'chore', section: 'Chores' },
          { type: 'chore', scope: 'deps', section: 'Dependencies' },
          { type: 'fix', scope: 'deps', section: 'Dependencies' },
        ],
      },
      parserOpts: {
        noteKeywords: ['BREAKING CHANGE', 'BREAKING CHANGES', 'BREAKING'],
      },
      writerOpts: {
        commitsSort: ['subject', 'scope'],
      },
    }],
    ['@semantic-release/changelog', {
      changelogFile: 'CHANGELOG.md',
      changelogTitle: '# Changelog',
    }],
    // Private package: only bumps the version in package.json, never publishes.
    ['@semantic-release/npm', { npmPublish: false }],
    ['@semantic-release/git', {
      assets: ['CHANGELOG.md', 'package.json'],
      message: 'chore(release): ${nextRelease.version} [skip release]\n\n${nextRelease.notes}',
    }],
    '@semantic-release/github',
  ],
};
