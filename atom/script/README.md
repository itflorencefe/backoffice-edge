# Atom smoke tests

Requires Bash, curl and jq, the local stack of this repo with the `atom` edge function served, and valid server-side Atom credentials in `supabase/functions/.env` (see [LOCAL_DEV.md](../../docs/LOCAL_DEV.md#function-secrets) and the [integration guide](../../docs/ATOM_BACKOFFICE_INTEGRATION.md)).

Prepare the local stack from the repository root:

```sh
npm run local:start                                   # stack + migrations (backoffice.backoffice_users exists)
docker exec -i supabase_db_bolt-migration psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < atom/script/local-smoke-user.sql                  # local smoke account
npm run local:functions                               # keep running (or npm run local:dev)
```

`backoffice.backoffice_users` already exists after the migrations, so no
migration is needed. `local-smoke-user.sql` creates the Supabase Auth user
`atom-smoke@example.test` with password `AtomSmoke-local-only-2026!` and an active
`viewer` row. It can be reapplied without resetting the database; run it again
after `npm run local:reset`. It is deliberately **not** in `supabase/seeds/`:
seeds are synced to the back office repos. Never apply it to a remote project.

The smoke scripts log in automatically with that account only at
`http://127.0.0.1:54321` or `http://localhost:54321`. To use another account,
set both `SUPABASE_EMAIL` and `SUPABASE_PASSWORD`, or supply a session JWT
in `SUPABASE_ACCESS_TOKEN` (takes precedence). Login uses Supabase Auth;
`backoffice_users` stores permissions, not passwords. The edge function
continues to reject anonymous callers and users without an active allowed role.

Run from the repository root:

```sh
./atom/script/smoke-get-product.sh
./atom/script/smoke-get-packs.sh
./atom/script/smoke-get-product-skus.sh
./atom/script/smoke-get-product-document.sh
./atom/script/smoke-get-product-document-html.sh
```

All five scripts POST JSON to `${SUPABASE_URL}/functions/v1/atom`:

| Script | Mode | Checks |
| --- | --- | --- |
| `smoke-get-product.sh` | `product` | Four base DTO fields, plus optional raw SDK offer/legal document and `included` arrays. Optional JSON export with `OUT_FILE`. |
| `smoke-get-packs.sh` | `packs` | Unique pack IDs, offer `id`/`providerId`, names, providers, prices, currency and `packOffer`. Packs, offers and associations all include validity dates and nullable boolean `live`. Exact DTO fields are checked. Empty packs are valid. Optional JSON export with `OUT_FILE`. |
| `smoke-get-product-skus.sh` | `skus` | Product/platform, counts, unique SKU ids and the five DTO fields: `id`, `name`, `external_id`, `price`, `units`. Null values are valid for external id, price and units; empty SKU arrays are valid. |
| `smoke-get-product-document.sh` | `discover` | Document catalog, formats and requested language. |
| `smoke-get-product-document-html.sh` | `documents` | Matching document format/language and non-empty `document.body_html` in the JSON response. |

Every test requires HTTP 200 and `ok:true`; transport errors, HTTP errors and invalid responses exit nonzero. `smoke-atom-common.sh` is a shared helper, sourced by the five tests.

Defaults match local development: `SUPABASE_URL=http://127.0.0.1:54321`, SKU product `2883`, `PLATFORM=appstore`, legal product `2930`, `LANGUAGE=fr`, `DOCUMENT_FORMAT=data_privacy`. Override any value through environment variables. `DOCUMENT_DATE` is optional; if omitted, the server uses today in UTC. Atom's environment is configured on the server with `ATOM_BASE_URL`.

The API key is resolved from `SUPABASE_ANON_KEY`, then `SUPABASE_PUBLISHABLE_KEY`, then (for local URLs only) `supabase status -o json` in `REPO_ROOT` (defaults to the backoffice-edge root), then the standard local demo key. Set `SUPABASE_ANON_KEY` explicitly for remote projects.

```sh
ATOM_PRODUCT_ID=2883 PLATFORM=playstore ./atom/script/smoke-get-product-skus.sh
ATOM_PRODUCT_ID=2930 LANGUAGE=fr ./atom/script/smoke-get-product-document.sh
DOCUMENT_FORMAT=data_privacy DOCUMENT_DATE=2026-10-27 OUT_FILE=/tmp/atom-document.html \
  ./atom/script/smoke-get-product-document-html.sh
```

Without `OUT_FILE`, the HTML test prints a short preview. With `OUT_FILE`, it writes the complete HTML after validation, replacing the file if it exists.

### Product retrieval

```sh
./atom/script/smoke-get-product.sh
ATOM_PRODUCT_ID=2930 INCLUDE=legaldocuments OUT_FILE=/tmp/atom-product.json \
  ./atom/script/smoke-get-product.sh
```

`INCLUDE` is omitted by default. The response is always `{ok:true, product:{...}}` containing `ProductDto`: `snowplowId`, `phoneSupport`, `emailSupport` and `smsPhoneSupport` (missing values are `null`). When the SDK product contains `offers` or `legaldocuments`, the DTO includes `offers` or `legalDocuments`, respectively, regardless of `INCLUDE`. Present empty arrays remain empty; missing or null relationships are omitted. Relationships remain raw SDK resources, including any metadata; only document and SKU response DTOs filter those resources. `OUT_FILE` exports only the product object, replacing the file if it exists.

Raw SDK `included` is preserved in the product DTO for document discovery fallback.

### Pack retrieval

```sh
./atom/script/smoke-get-packs.sh
ATOM_PRODUCT_ID=2930 OUT_FILE=/tmp/atom-packs.json \
  ./atom/script/smoke-get-packs.sh
```

The default product is `2883`. The server requests a fixed set of relationships. The response is `{ok:true, packs:[...]}` with pack IDs,
names and offers, without product details. Missing names, providers and prices
may be `null`; zero prices are valid. Each offer also includes `currency` as
the ID from `offer.currency.id` as a string, or `null` when missing or empty. Both packs and offers include `validityStart`, `validityEnd`
and `validityTz` (string or `null`). Packs, offers and pack offers include `live` (boolean or `null`), calculated by the edge function; resources remain in the catalog regardless of their validity dates. Offers also include `id` and nullable `providerId`.
Each offer includes a nested `packOffer` with the association's `id` (nonempty
string or `null`), `used` (boolean or `null`), `data` (object or `null`) and its own
`validityStart`, `validityEnd` and `validityTz`. The association also includes `live`. All seven fields are required, and extra fields are rejected. Missing values are `null`.
`OUT_FILE` exports `{packs:[...]}` after
validation, replacing the file if it exists.
