# Atom dev kit

Developer tools for the `atom` edge function (`supabase/functions/atom/`). Imported from the `atom` repo.
This folder is **not synced** to the back office repos (the sync owns only `supabase/`).

| Path | What |
|---|---|
| [`runner/`](runner/README.md) | Node CLI that calls Atom directly with the SDK (no Supabase): reference for the edge services. `npm test` runs its unit tests. |
| [`script/`](script/README.md) | Bash smoke tests that call the `atom` edge function on the local stack, logged in as a local backoffice viewer. |
| [`script/local-smoke-user.sql`](script/local-smoke-user.sql) | Local-only Auth user + `viewer` row for the smoke tests. Never apply it remotely. |

API contract and backoffice integration: [`docs/ATOM_BACKOFFICE_INTEGRATION.md`](../docs/ATOM_BACKOFFICE_INTEGRATION.md).
