# DV Live Edge Function

Command proxy for the DV Live voting API. The edge function attaches a fixed DV Live
API token from server secrets; the app never sends that credential. Projects that do
not use DV Live can leave the secrets unset: every command then answers
`500 SERVER_MISCONFIGURED`, the catalog still works.

Import map: `@digitalvirgo/dvlive-api` → `../_shared/dvlive-sdk` (local vendor).
When the package is published under `@digitalvirgo`, change only `deno.json` to
`npm:@digitalvirgo/dvlive-api@<version>` and add a function `.npmrc` in each repo
(same pattern as `pulsar`; `.npmrc` is never synced). No call-site edits.

Tests: `supabase/tests/dvlive_test.ts`.

## Secrets

Local: `supabase/functions/.env` (never committed)

| Variable | Required | Notes |
|----------|:--------:|-------|
| `DVLIVE_API_TOKEN` | yes | Fixed DV Live bearer token (no `Bearer` prefix in the value) |
| `DVLIVE_ENV` | yes | `STAG` or `PROD` |
| `DVLIVE_LOG_ENABLE` | no | `TRUE` / `FALSE` |
| `DVLIVE_LOG_LEVEL` | no | `WARNING` (default), `INFO`, or `DEBUG` |
| `APP_JWT_SECRET` | yes | Already required by `bolt-auth-proxy` |

Remote:

```bash
supabase secrets set DVLIVE_ENV=STAG DVLIVE_API_TOKEN=... --project-ref <project-ref>

supabase functions deploy dvlive --no-verify-jwt --project-ref <project-ref>
```

`npm run backend:deploy` deploys it with the other functions (`config.toml` already sets
`verify_jwt = false`).

Local serve:

```bash
supabase functions serve dvlive
```

`verify_jwt = false` is intentional: the function verifies the custom app JWT itself.

## App contract

**Endpoint:** `{SUPABASE_URL}/functions/v1/dvlive`

**Headers (every command, including show reads):**

```http
apikey: <SUPABASE_ANON_KEY>
Authorization: Bearer <access_token from bolt-auth-proxy>
```

Do **not** send `bearer-token`. Do **not** add `EXPO_PUBLIC_DVLIVE_BEARER_TOKEN`.
Show / choice UUIDs stay client query params (`uuid`, `showVoteUuid`).
`EXPO_PUBLIC_DVLIVE_SHOW_VOTE_UUID` may remain on the app; it is not a secret.

**Identity:** for `getVoter`, `createVoter`, and `castVote`, the server sets
`userRef` / `uniqRef` from JWT `absolute_reference` (top-level or `app_metadata`).
Query `userRef` and body `uniqRef` are ignored / overwritten. `sub` is the
internal profile id and is **not** the DV Live voter id.

**Envelope:**

```json
{ "ok": true, "data": { } }
```

```json
{ "ok": false, "error": { "message": "...", "code": "AUTH_REQUIRED", "details": null } }
```

Error codes: `AUTH_REQUIRED`, `FORBIDDEN`, `METHOD_NOT_ALLOWED`, `INVALID_JSON`,
`VALIDATION`, `SERVER_MISCONFIGURED`, `UPSTREAM_TIMEOUT`, `UPSTREAM_ERROR`,
`INTERNAL_ERROR`. Upstream HTTP errors keep the upstream status; when DV Live
returns JSON, it is placed in `error.details`.

**Catalog** (missing or unknown `mode`): `{ "ok": true, "data": { "name": "DVLive", "modes": { ... } } }` — no upstream call. JWT is not required for the catalog.

## Commands

### `getShowVote`

```http
GET /functions/v1/dvlive?mode=getShowVote&uuid={SHOW_VOTE_UUID}
Authorization: Bearer <app-jwt>
apikey: <anon-key>
```

Success `data` shape (SDK `ShowVote`): show name/dates, optional `round` with `choices[]`
(`uuid`, `firstname`, `lastname`, `status`, pictures, …).

### `getShowVoteChoice`

```http
GET /functions/v1/dvlive?mode=getShowVoteChoice&uuid={CHOICE_UUID}
Authorization: Bearer <app-jwt>
apikey: <anon-key>
```

Success `data`: participant detail (`ShowVoteChoice`).

### `createVoter`

```http
POST /functions/v1/dvlive?mode=createVoter&showVoteUuid={SHOW_VOTE_UUID}
Authorization: Bearer <app-jwt>
apikey: <anon-key>
Content-Type: application/json

{ "email": null, "phone": null }
```

`uniqRef` is set from `absolute_reference`. Success `data`: `{ "status", "code", "message" }`.

### `getVoter`

```http
GET /functions/v1/dvlive?mode=getVoter&showVoteUuid={SHOW_VOTE_UUID}
Authorization: Bearer <app-jwt>
apikey: <anon-key>
```

Success `data`: voter (`uniqRef`, `remainingPoints`, `userFraudStatus`, `balance`, …).

### `castVote`

```http
POST /functions/v1/dvlive?mode=castVote&showVoteUuid={SHOW_VOTE_UUID}
Authorization: Bearer <app-jwt>
apikey: <anon-key>
Content-Type: application/json

{
  "votes": [{ "choiceUuid": "...", "nbVotes": 1 }],
  "sessionToken": null,
  "phoneFingerPrint": null,
  "ip": null,
  "userAgent": null,
  "uniqSubscriptionId": null
}
```

`votes` is required (at least one entry; `nbVotes` positive integer). Optional fields
may be omitted. Success `data`: `{ "status", "code", "message", "nbVoteRemaining"? }`.

## App migration

Delta from the app-team draft adapter: `doc/migration/app/dvlive.md` in the bravigo-migration repo.
