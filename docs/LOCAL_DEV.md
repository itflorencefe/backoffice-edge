# Local development

Run this repo's working tree (migrations, seeds, edge functions) on a local Supabase stack and point a back
office (e.g. the starter) at it, before any pull request or sync.

Requirements: Docker, the Supabase CLI, Deno, the back office checkout next to this repo
(`../starter-backoffice-template`).

## Daily use: one command

```sh
npm run local:dev              # → http://localhost:5174
```

It starts the stack (or reuses it) and applies the new migrations, copies the starter's `.npmrc` into the
functions that need it, serves the edge functions (hot reload), writes the starter's `.env.edge.local` and runs
the starter on <http://localhost:5174>. Output lines are prefixed `[functions]` / `[app]`; keys are never printed.
**Ctrl+C** stops the functions and the app; the stack keeps running, so the next start takes seconds
(`npm run local:stop` stops it). Options: `npm run local:dev -- --port 5175`, `-- --no-functions`.

## Commands

| Command | What it does |
|---|---|
| `npm run local:dev` | All of the above in one terminal |
| `npm run local:start` | Starts the stack (without the functions container) and applies the migrations not yet applied |
| `npm run local:migrate` | Applies new migrations, keeping the data (after adding a migration) |
| `npm run local:reset` | Recreates the database from migrations and seeds: **deletes the local data** |
| `npm run local:npmrc -- --from <file>` | Copies an `.npmrc` with the `@digitalvirgo` token into the functions that need it (gitignored) |
| `npm run local:functions` | Only serves the edge functions from `supabase/functions` with hot reload (keep it running) |
| `npm run local:consumer -- --target <dir>` | Only writes `<dir>/.env.edge.local` (another back office) |
| `npm run local:status` | URLs of the stack (API, Studio, mail); keys are never printed |
| `npm run local:stop` | Stops the stack; the data is kept |

## First run

`npm run local:dev`. The first run downloads the Docker images (a few minutes). The back office opens its
first-admin setup on an empty database (`create-first-user`). Studio (<http://127.0.0.1:54323>) shows the `backoffice` schema.

If the local database was created from another repo with the same `project_id` and `local:start` reports
migrations it does not know, run `npm run local:reset`.

## Function secrets

`supabase/functions/.env` (gitignored, never synced) is passed to the functions (`local:dev`, `local:functions`); restart after changing it. Only the functions you test
need their values, e.g. Atom:

```sh
ATOM_BASE_URL=...
ATOM_USER=...
ATOM_SDK_ACCESS_KEY=...
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are set by the CLI.

## Atom smoke tests

`atom` requires the session of an active backoffice user. To call it from the terminal, create the local smoke
account once (again after `local:reset`) and run the scripts while the functions are served:

```sh
docker exec -i supabase_db_bolt-migration psql -U postgres -d postgres -v ON_ERROR_STOP=1 < atom/script/local-smoke-user.sql
./atom/script/smoke-get-packs.sh
```

Details, the other scripts and the direct Atom runner: [`atom/README.md`](../atom/README.md).

## How the back office uses it

`local:dev` runs `vite --mode edge` in the back office: Vite loads `.env.edge.local` (gitignored by `*.local`) over
`.env.local`, so the normal `npm run dev` keeps using the remote project. Port 5174 is a different browser origin,
so the Supabase URL saved in the browser by the normal dev server is not reused.

Change a function → reloaded on save (`local:dev` / `local:functions`). Add a migration → `npm run local:migrate`. Front-end
changes in the back office reload as usual. When it works, open the PR here; the sync brings the same files to the
back office.

## Troubleshooting: 502 on every API call

`local:start` fails its health check and `docker logs supabase_kong_bolt-migration` shows `upstream:
"http://127.0.0.1:..."`: containers inherit the host DNS search domains, and some home routers answer `127.0.0.1`
for any name under their domain, so the API gateway calls itself. Remove the search domains from containers:

```sh
echo '{ "dns-search": ["."] }' | sudo tee /etc/docker/daemon.json   # merge by hand if the file exists
sudo systemctl restart docker
npm run local:start
```
