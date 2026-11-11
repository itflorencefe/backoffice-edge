# atom — Atom legal API reference runner

A small Node.js script that calls **Atom** legal document APIs from the command line using parameters declared in `config.json`.

It is intentionally minimal — one HTTP client (`atomLegalClient.js`) and one dispatcher (`run.js`) — so it can serve as a spec/reference when porting the calls into the Supabase edge function or another runtime.

API overview: [`atom-legal-api.md`](atom-legal-api.md).  
Parent kit: [`../../docs/ATOM_BACKOFFICE_INTEGRATION.md`](../../docs/ATOM_BACKOFFICE_INTEGRATION.md).

## Requirements

- Node.js >= 18 (uses the built-in `fetch`)
- Repoflow token for `@digitalvirgo/atom-api`: copy the starter's `.npmrc` into this folder (gitignored, like every `.npmrc` here) or export `NPM_TOKEN`

## Setup

1. Copy the example config and edit it:

   ```bash
   cp config.example.json config.json
   ```

2. Fill in `staging` / `production` (`baseUrl`, `user`, `sdkAccessKey`) and action blocks.

   ```json
   {
     "environment": "staging",
     "staging": {
       "baseUrl": "https://staging.atom.digitalvirgo.com",
       "user": "…",
       "sdkAccessKey": "…"
     },
     "action": "discover",
     "discover": {
       "atom_product_id": 127,
       "language": "fr"
     }
   }
   ```

3. Install:

   ```bash
   export NPM_TOKEN="your-repoflow-token"
   npm install
   ```

## Usage

```bash
npm run help
npm run help -- discover

npm run login
npm run getProduct
npm run getPacks
npm run discover
npm run getDocumentHtml

npm start                  # uses config.action
node run.js discover
```

### `getDocumentHtml`

- `document_format` — path slug from discover (`documentType`, e.g. `data_privacy`)
- `outFile` — if set, writes HTML to disk; otherwise prints to stdout

## Actions

| Action | Summary |
| --- | --- |
| `login` | Basic → Bearer token (sanity check) |
| `getProduct` | Product DTO with support fields and optional raw SDK offers/legal documents |
| `getProductSkus` | Pack-linked product SKUs for the requested platform |
| `getPacks` | Packs with all associated offers, prices, currencies and providers |
| `discover` | List formats with HTML available in the requested language |
| `getDocumentHtml` | Fetch one document HTML |

## Files

- `atomLegalClient.js` — Atom login, discover, HTML (aligned with edge `index.ts`)
- `run.js` — config loader and action dispatch
- `config.example.json` — template; `config.json` is gitignored

Apps in production should call **`atom`** on Supabase with `atom_product_id` — see [`../../docs/ATOM_BACKOFFICE_INTEGRATION.md`](../../docs/ATOM_BACKOFFICE_INTEGRATION.md).


### `getProduct`

Add a `getProduct` block to `config.json` (also present in `config.example.json`):

```json
{"getProduct":{"atom_product_id":2930}}
```

Run `npm run getProduct`. Optional `getProduct.include` is a comma-separated relationship string such as `legaldocuments` or `offers.offercapabilities.sku,offers.platform,offers.packoffers.pack`. Omit it to use the SDK defaults. The DTO always includes `snowplowId`, `phoneSupport`, `emailSupport` and `smsPhoneSupport`, using `null` for missing values. Optional `getProduct.outFile` exports the product JSON to disk, replacing the file if it exists; otherwise the CLI prints `{ok:true, product:{...}}`.

`AtomLegalClient.getProduct(atom_product_id, include?)` always returns `ProductDto`. It contains the four support/analytics fields, plus `offers` and `legalDocuments` whenever the SDK product contains the corresponding relationships. Present empty arrays stay empty; missing or null relationships are omitted. This check depends on the SDK response, independently of `include`. These relationships are passed through unchanged from the SDK. Document discovery and SKU retrieval own normalization and construction of their final DTOs, excluding Atom metadata from those final responses. Document discovery and SKU retrieval reuse this method with their required includes, matching the Supabase services.

The product DTO also preserves raw SDK `included` resources. Discovery falls back to its legal documents only when `legalDocuments` contains no valid documents, matching the Supabase document service.

### `getPacks`

Add a `getPacks` block to `config.json` (also present in `config.example.json`):

```json
{"getPacks":{"atom_product_id":2930}}
```

Run `npm run getPacks`, or set `action` to `getPacks` and run `npm start`.
The output always groups offers under packs. Each pack can have multiple offers,
for example one per provider for buying 50 votes, and another set for buying 70 votes.
Each offer contains a single `provider`, taken from the Atom SDK `offer.platform`
relationship used for purchase channels (for example Apple or Google).

Each offer also includes `price` from Atom, or `null` when missing. A zero price is preserved.
The runner includes `offers.currency` automatically and exposes `currency` as
the ID from `offer.currency.id` as a string (for example, `"1"`).
A missing or empty currency ID produces `currency: null`.

The SDK distinguishes `Offer` from `PackOffer` (the association between an offer
and a pack). Each entry keeps `id` as the offer ID and exposes a nested
`packOffer` with its own `id`, `validityStart`, `validityEnd`, `validityTz`,
`used` and `data`. Changes to the association are returned here;
price, currency, name and provider still come from `Offer`. Missing association
fields are `null`; `used: false` and empty `data` are preserved. Offer and
association validity is exposed through the date bounds; neither contains `expired`.

Packs, offers and pack offers include `validityStart`, `validityEnd` and `validityTz`.
Only packs include the computed `expired` field.
The start and end are extracted from Atom’s validity range without quotes or
range delimiters; absent bounds are `null`. Explicit infinity values are retained.
The raw `validity` field is omitted. Pack expiry is evaluated at
the time of the request, using the upper bound of Atom's validity range and its
timezone. `expired: true` means the upper bound has passed; `false` means it has
not passed or the range has no end (`(,)` or `infinity`). Missing or unparseable
validity produces `expired: null`; a timestamp without an offset also requires a
valid `validityTz`. An exclusive upper bound expires at that instant; an inclusive
bound expires after it. A future start date does not make a resource expired.
All resources remain in the output regardless of their validity dates. A pack's
expiry depends only on its own validity.

Illustrative output (IDs, names and prices are examples):

```json
{
  "ok": true,
  "packs": [
    {
      "id": "50",
      "name": "50 votes",
      "validityStart": null,
      "validityEnd": null,
      "validityTz": "UTC",
      "expired": false,
      "offers": [
        {
          "id": "501",
          "packOffer": {
            "id": "9001",
            "validityStart": null,
            "validityEnd": null,
            "validityTz": "UTC",
            "used": false,
            "data": {}
          },
          "name": "50 votes Apple",
          "validityStart": null,
          "validityEnd": null,
          "validityTz": "UTC",
          "price": 4.99,
          "currency": "1",
          "provider": {
            "id": "1",
            "name": "Apple"
          }
        },
        {
          "id": "502",
          "packOffer": {
            "id": "9002",
            "validityStart": null,
            "validityEnd": null,
            "validityTz": "UTC",
            "used": false,
            "data": {}
          },
          "name": "50 votes Google",
          "validityStart": null,
          "validityEnd": null,
          "validityTz": "UTC",
          "price": 4.99,
          "currency": "1",
          "provider": {
            "id": "2",
            "name": "Google"
          }
        }
      ]
    },
    {
      "id": "70",
      "name": "70 votes",
      "validityStart": null,
      "validityEnd": null,
      "validityTz": "UTC",
      "expired": false,
      "offers": [
        {
          "id": "701",
          "packOffer": {
            "id": "9003",
            "validityStart": null,
            "validityEnd": null,
            "validityTz": "UTC",
            "used": false,
            "data": {}
          },
          "name": "70 votes Apple",
          "validityStart": null,
          "validityEnd": null,
          "validityTz": "UTC",
          "price": 6.99,
          "currency": "1",
          "provider": {
            "id": "1",
            "name": "Apple"
          }
        },
        {
          "id": "702",
          "packOffer": {
            "id": "9004",
            "validityStart": null,
            "validityEnd": null,
            "validityTz": "UTC",
            "used": false,
            "data": {}
          },
          "name": "70 votes Google",
          "validityStart": null,
          "validityEnd": null,
          "validityTz": "UTC",
          "price": 6.99,
          "currency": "1",
          "provider": {
            "id": "2",
            "name": "Google"
          }
        }
      ]
    }
  ]
}
```


The runner requests `offers`, `offers.packoffers.pack`, `offers.platform` and `offers.currency`.
Packs are deduplicated by ID across all offers; entries are deduplicated by offer ID and pack-offer ID
within each pack. Distinct pack-offer links for the same offer are retained;
links without an ID are deduplicated by offer ID. Distinct offers from the same provider are retained. An offer
linked to multiple packs appears under each one. Offers without a valid pack
are omitted; no linked packs produces `packs: []`. A missing provider produces
`provider: null`. IDs are strings. Names use the first nonempty localized value,
or `null` when missing.

The required relationships are fixed; the response contains only packs with their offers, prices, currencies and providers.
`AtomLegalClient.getPacks(atom_product_id)` returns `{packs: [...]}`.
The CLI prints `{ok:true, packs:[...]}`. Optional `getPacks.outFile` writes
`{packs:[...]}` to a JSON file, replacing it if it exists.
