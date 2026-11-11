# Atom legal API — runner reference

**Description:** Atom JSON:API legal documents (discover + HTML visualisation)  
**Package:** `@digitalvirgo/atom-api` (Repoflow)  
**Kit edge proxy:** `{SUPABASE_URL}/functions/v1/atom`

Production apps should use the **edge function**, not direct Atom calls from the client. This document supports the [reference runner](README.md) and mirrors [`../../supabase/functions/atom/`](../../supabase/functions/atom/).

---

## Authentication

- **Type:** HTTP Basic Auth → Bearer token
- **Login:** `GET {baseUrl}/auth/token` with `Authorization: Basic base64(user:sdkAccessKey)`
- **API calls:** `Authorization: Bearer {access_token}` via `JsonApiService`

Configure `staging` / `production` blocks in `config.json` (`baseUrl`, `user`, `sdkAccessKey`).

---

## Table of contents

1. [Runner vs edge](#runner-vs-edge)
2. [Runner action map](#runner-action-map)
3. [Atom paths used by the kit](#atom-paths-used-by-the-kit)
4. [Edge function modes (apps)](#edge-function-modes-apps)
5. [Product identification](#product-identification)

---

## Runner vs edge

| Layer | Product id | Credentials |
|-------|------------|-------------|
| **Runner** | `atom_product_id` in config | SDK user/key in `config.json` |
| **Edge** | Required `atom_product_id` in POST JSON | `ATOM_*` secrets on Supabase only |

---

## Runner action map

| Runner action | What it does |
|---------------|--------------|
| `login` | Basic auth → prints token prefix |
| `getProduct` | Always return ProductDto; optional includes fetch raw offers/legal documents |
| `getProductSkus` | Shared product retrieval with SKU, platform and pack relationships, then build the SKU DTO |
| `getPacks` | Return `{ok:true, packs:[...]}` with packs as `{id, name, validityStart, validityEnd, validityTz, expired, offers: [{id, packOffer: {id, validityStart, validityEnd, validityTz, used, data}, name, validityStart, validityEnd, validityTz, price, currency: string | null, provider: {id, name}}]}`; provider comes from `offer.platform`, currency from `offer.currency.id` as a string (or `null` when missing or empty). Only pack expiry is computed from its validity upper bound (`true`/`false`, or `null` if unknown); expired resources are retained. Product details and raw included resources are omitted |
| `discover` | Shared product retrieval with `include: "legaldocuments"`, then list catalog metadata |
| `getDocumentHtml` | Fetch HTML directly using `document_format`, language and optional date |

Config keys (see [README](README.md)):

| Action | Required config |
|--------|-----------------|
| `getProduct` | `getProduct.atom_product_id` (optional: `getProduct.include`, `getProduct.outFile`) |
| `getProductSkus` | `getProductSkus.atom_product_id`, `getProductSkus.platform` |
| `getPacks` | `getPacks.atom_product_id` (optional: `getPacks.outFile`) |
| `discover` | `discover.atom_product_id`, `discover.language` |
| `getDocumentHtml` | `getDocumentHtml.atom_product_id`, `getDocumentHtml.language`, `getDocumentHtml.document_format` |

---

## Atom paths used by the kit

| Step | Method / API | Path pattern |
|------|--------------|--------------|
| Login | `GET` | `/auth/token` |
| Catalog | `JsonApiService.find(Product, …)` | include `legaldocuments` |
| Probe / HTML | `getVisualiseLegalDocuments` | `products/{atomProductId}/document/{documentType}/html/{language}/{date}` |

`documentType` comes from the legal document resource (e.g. `data_privacy`, `cookies`), not the display name.

`date` defaults to today (UTC `YYYY-MM-DD`) when omitted.

---

## Edge function modes (apps)

Full contract: [`../../docs/ATOM_BACKOFFICE_INTEGRATION.md`](../../docs/ATOM_BACKOFFICE_INTEGRATION.md).

| Mode | Purpose |
|------|---------|
| `product` | Return `{ok:true, product:{...}}` with optional `include` relationships |
| `skus` | Return pack-linked SKUs for the required `platform` |
| `discover` | List legal catalog metadata, plus `formatsDiscovered` |
| `documents` | Return `document.body_html` (or raw HTML with `Accept: text/html`) |

Only POST JSON is supported. `mode` is required and must be `product`, `discover`, `documents` or `skus`; it has no default. `atom_product_id` is required in all modes. Legal requests accept `language` (default `fr`), `format` (required for `documents`) and optional `date`. SKU requests require `platform`.

There is no `product_slug` fallback or client environment selector. Atom credentials and environment are server configuration. Missing or invalid required inputs return 400 before authentication.

---

## Product identification

Use the numeric `atom_product_id` directly, without database access.

The runner only supports `atom_product_id`.

Legal source: always Atom via the edge function — see [`../../docs/ATOM_BACKOFFICE_INTEGRATION.md`](../../docs/ATOM_BACKOFFICE_INTEGRATION.md).


`getPacks` keeps the `Offer` ID in `offers[].id`. The nested `packOffer` exposes the distinct SDK association ID and its own validity dates, `used` and `data` (missing values are `null`). Entries are deduplicated by both offer ID and pack-offer ID within each pack, retaining distinct links. Offers and pack offers do not expose `expired`.
