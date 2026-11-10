<!--
Pull requests go to develop. main is updated only by Actions → Release.
Title = Conventional Commit, it decides the next version:
  feat: …            → minor
  fix: / chore: / docs: / refactor: / ci: …  → patch
  feat!: … or a "BREAKING CHANGE:" footer      → major
-->

## What

## Why

## Checklist

- [ ] Tests added or updated in `supabase/tests/` (`npm test`)
- [ ] New schema changes are in a **new** migration file (released migrations are never edited)
- [ ] Docs updated (`docs/`, README) when a contract or a command changes
- [ ] Tried locally against the starter when the back office uses it (`docs/LOCAL_DEV.md`)
