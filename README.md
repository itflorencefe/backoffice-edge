# backoffice-edge

Single source of the `supabase/` folder shared by the back office repos: edge functions, migrations, seeds, `config.toml` and the edge function tests. Change these files here, never in the repos that use them: every release (develop → `main`) opens an update pull request in each registered repo.

## Try a change locally

Run the working tree on a local Supabase stack and use it from the starter before opening a PR: see [`docs/LOCAL_DEV.md`](docs/LOCAL_DEV.md) (`npm run local:start`, `local:functions`, `local:dev`).

## How a change travels (git flow)

`develop` is the integration branch, `main` holds only released versions.

1. **Branch from `develop`** (`feature/...`, `fix/...`) and open the **pull request on `develop`**. Use
   [Conventional Commits](https://www.conventionalcommits.org/) in the merged commit / PR title: they decide the
   next version (`feat` → minor, `fix` / `chore` / `docs` / `refactor` / `ci` → patch, `BREAKING CHANGE` → major).
   - `Tests` runs the edge function tests, the sync script tests and the migrations rule. It is required to merge,
     and fails for a PR opened on `main`.
   - `Preview on consumers` applies the change to each registered repo (locally, nothing is pushed) and runs that
     repo's tests. One comment on the PR lists the result per repo.
2. **Release: Actions → Release → Run workflow** (type `release`). It:
   - fast-forwards `main` to `develop` and runs the tests on it;
   - runs semantic-release on `main`: version from the commits since the last tag, `package.json` and
     `CHANGELOG.md` committed (`chore(release): <version> [skip release]`), tag `<version>`, GitHub release;
     it runs even when `develop` brings nothing new, so commits already on `main` and not tagged yet are released
     (the first run tags `1.0.0`);
   - fast-forwards `develop` to `main`, so both have the release commit;
   - starts `Propagate to consumers`, which opens or updates one PR per repo, on the branch `edge-sync`, titled
     `chore(edge): backoffice-edge <version> (<commit>)`.
3. **Merge in each repo.** The repo's own required checks (its `Tests` workflow) run on that PR. Then deploy the
   backend there (`npm run backend:deploy`).

A repo that falls behind keeps an open, red `edge-sync` PR.

## What the sync owns in a repo

| Path | Rule |
|---|---|
| `supabase/config.toml`, `supabase/functions/`, `supabase/seeds/`, `supabase/tests/` | Overwritten with this repo's files |
| `supabase/migrations/` | New files are added; existing ones are never changed or deleted |
| `.edge-sync.json` | Written by the sync: version, commit and a hash per synced file |

Never touched: anything the repo has and this repo never shipped (its own functions, migrations), `supabase/tests/local/` (repo-only tests), `.npmrc`, `.env*`, `supabase/.temp/`, and the paths listed in the repo's `exclude`.

A file edited in a repo is replaced at the next sync and listed as **Local edits replaced** in the PR. To keep a customization, add its path to `exclude`.

## Register a repo

1. Add it to [`consumers.json`](consumers.json) with a pull request here:
   ```json
   { "repo": "itflorencefe/my-backoffice", "branch": "main", "exclude": ["supabase/functions/pulsar"] }
   ```
2. Install the **edge-sync** GitHub App on that repo.
3. Run **Actions → Propagate to consumers** with `repo` set to it, to open its first PR.

New Bolt projects created from the starter template are new repos: register each one, or it stays on the version it was created from.

## Rules for changes

- **Migrations are append-only.** A database that applied a migration never runs it again, so put every schema change in a new file (`YYYYMMDDHHMMSS_name.sql`). `scripts/check-migrations.mjs` blocks PRs that modify, rename or delete a migration that is already on `develop`. The baseline is frozen.
- **Tests come with the change.** Edge function tests live in `supabase/tests/` (see its README). Repo-specific tests go in `supabase/tests/local/` of that repo.
- **No secrets in this repo.** `.npmrc` (private `@digitalvirgo` registry token) stays in each repo and is never synced.
- **Never edit `version` in `package.json` or `CHANGELOG.md` by hand**: the Release workflow writes them; the version is shown in the consumer PR title and in `.edge-sync.json`.

## One-time setup

1. Create a GitHub App from the `itflorencefe` account (personal account: *Settings → Developer settings → GitHub Apps → New GitHub App*, <https://github.com/settings/apps/new>), named for example `itflorencefe-edge-sync`:
   - repository permissions: **Contents** read and write, **Pull requests** read and write, **Issues** read and write (release comments), **Metadata** read;
   - no webhook.

   After changing the permissions of an existing App, accept them in *Settings → Applications → Installed GitHub Apps*.
2. Install it on this repo and on every consumer repo.
3. In this repo, *Settings → Secrets and variables → Actions*:
   - variable `EDGE_SYNC_APP_ID`: the App ID;
   - secret `EDGE_SYNC_APP_PRIVATE_KEY`: a private key generated for the App;
   - optional variable `RELEASE_ACTORS`: comma-separated GitHub logins allowed to run Release.
4. Create `develop` from `main` and make it the **default branch** (*Settings → General → Default branch*), so pull requests open on it.
5. *Settings → Rules → Rulesets → New ruleset → New branch ruleset*, twice. In both: Enforcement **Active**, Bypass list → the edge-sync App (**Always allow**), rules **Restrict deletions** and **Block force pushes**.
   - `main` (target pattern `main`): also **Restrict updates**. Only the Release workflow (App token) moves `main`.
   - `develop` (target pattern `develop`): also **Require a pull request before merging** and **Require status checks to pass** with `Edge tests`. The App bypass lets Release fast-forward `develop` after a version.

   Tags need no ruleset (semantic-release creates `<version>` with the App token). To protect them, add a tag ruleset on `*` with the same bypass and **Restrict creations / updates / deletions**.

## Local commands

```bash
npm test                    # edge function tests (Deno)
npm run test:sync           # sync script tests (Node)
npm run check:migrations    # migrations rule against origin/develop
node scripts/sync-consumer.mjs --target ../starter-backoffice-template --dry-run   # what a sync would change
```

`npm install` enables the pre-commit hook (`.githooks/pre-commit`), which runs both test suites.
