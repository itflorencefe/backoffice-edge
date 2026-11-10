# Local development

Run this repo's working tree (migrations, seeds, edge functions) on a local Supabase stack and point a back
office (e.g. the starter) at it, before any pull request or sync.

Requirements: Docker, the Supabase CLI, Deno, the back office checkout next to this repo
(`../starter-backoffice-template`).

## Commands

| Command | What it does |
|---|---|
| `npm run local:start` | Starts the stack (without the functions container) and applies the migrations not yet applied |
| `npm run local:migrate` | Applies new migrations, keeping the data (after adding a migration) |
| `npm run local:reset` | Recreates the database from migrations and seeds: **deletes the local data** |
| `npm run local:npmrc -- --from <file>` | Copies an `.npmrc` with the `@digitalvirgo` token into the functions that need it (gitignored) |
| `npm run local:functions` | Serves the edge functions from `supabase/functions` with hot reload (keep it running) |
| `npm run local:dev` | Writes `../starter-backoffice-template/.env.edge.local` and runs its dev server on <http://localhost:5174> |
| `npm run local:consumer -- --target <dir>` | Only writes `<dir>/.env.edge.local` (another back office) |
| `npm run local:status` | URLs of the stack (API, Studio, mail); keys are never printed |
| `npm run local:stop` | Stops the stack; the data is kept |

## First run

```sh
npm run local:start
npm run local:npmrc -- --from ../starter-backoffice-template/.npmrc   # atom, pulsar, bolt-auth-proxy
npm run local:functions        # terminal 1
npm run local:dev              # terminal 2 → http://localhost:5174
```

The back office opens its first-admin setup on an empty database (`create-first-user`, served by
`local:functions`). Studio (<http://127.0.0.1:54323>) shows the `backoffice` schema.

If the local database was created from another repo with the same `project_id` and `local:start` reports
migrations it does not know, run `npm run local:reset`.

## Function secrets

`supabase/functions/.env` (gitignored, never synced) is passed to `local:functions`. Only the functions you test
need their values, e.g. Atom:

```sh
ATOM_BASE_URL=...
ATOM_USER=...
ATOM_SDK_ACCESS_KEY=...
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are set by the CLI.

## How the back office uses it

`local:dev` runs `vite --mode edge` in the back office: Vite loads `.env.edge.local` (gitignored by `*.local`) over
`.env.local`, so the normal `npm run dev` keeps using the remote project. Port 5174 is a different browser origin,
so the Supabase URL saved in the browser by the normal dev server is not reused.

Change a function → saved and reloaded by `local:functions`. Add a migration → `npm run local:migrate`. Front-end
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
