# Atom Integration for the Backoffice

This guide explains how to integrate the `atom` Edge Function into a backoffice and how to display packs, offers, saved configurations, and validation messages.

## 1. Integration overview

The backoffice uses two modes of the same edge function:

| Mode | When to call it | What it returns |
| --- | --- | --- |
| `checkLocalPacks` | When opening the pack section or pressing Reload | Saved database configurations, comparison warnings, and check errors. |
| `packs` | When opening Add new pack or Edit | Atom packs and offers, including their live states, original dates, prices, and currencies. |

`checkLocalPacks` is the API mode name. It compares saved configurations with Atom; the caller does not perform those comparisons.

Saving, deleting, and reordering are database operations. They do not require an additional Atom mode.

## 2. Calling the edge function

Send a JSON request to `POST /functions/v1/atom`:

```json
{
  "mode": "checkLocalPacks",
  "atom_product_id": 2883
}
```

Use the numeric Atom product ID associated with the product selected in the backoffice. The value above is illustrative. An Atom product ID is distinct from a service slug, a product slug, or an internal product UUID.

With a configured backoffice Supabase client:

```ts
const { data, error } = await supabase.functions.invoke('atom', {
  body: {
    mode: 'checkLocalPacks',
    atom_product_id: atomProductId,
  },
});

if (error) throw error;
if (!data || data.ok !== true) {
  throw new Error(data?.error ?? 'Invalid Atom response.');
}
```

Use the backoffice's operator session for authenticated Supabase requests. The `checkLocalPacks` database read forwards the incoming Authorization header and uses caller RLS permissions.

Access control: **every mode** (`discover`, `documents`, `product`, `packs`, `checkLocalPacks`, `skus`) requires the operator session of an active backoffice user (viewer, editor or admin), checked before the body is read:

| Case | Status | `error` |
|---|---|---|
| No `Authorization: Bearer <jwt>` / token not valid for Supabase Auth | `401` | `Unauthorized` |
| App user token (`app_role = app_user`) | `403` | `App users are not authorized for this endpoint` |
| Signed in, no active `backoffice.backoffice_users` row with viewer / editor / admin | `403` | `Insufficient permissions` |

Apps do not call `atom`: they read packs through `get-product-packs` and published documents (Atom ones included) through `get-product-document`.

Atom credentials belong on the server. The browser does not log in to Atom or receive those credentials.

## 3. Opening the pack section

Call `checkLocalPacks` once when entering the section. Call it again when the operator presses Reload.

The response has this structure:

```ts
interface CheckLocalPacksResponse {
  ok: true;
  packs: ProductPack[];
  messages: SavedPackWarning[];
  errors: string[];
}

interface SavedPackWarning {
  packId: string;
  code:
    | 'pack-expiry-changed'
    | 'offer-expiry-changed'
    | 'pack-offer-expiry-changed'
    | 'pack-missing'
    | 'offer-missing'
    | 'pack-offer-missing'
    | 'pack-offer-ambiguous'
    | 'price-changed';
  message: string;
}
```

The function reads saved configurations for the requested product, orders them by `sortOrder` and then `packId`, and compares them with one Atom pack-list fetch. If there are no saved configurations, it skips Atom and returns empty arrays.

### Saved-pack table

Display `packs` in the order returned by the function. Do not sort them alphabetically in the UI.

| Data | Recommended presentation |
| --- | --- |
| `packName` | Main editable display title. |
| `packId` | Secondary identifier. |
| `value` | Pack value. |
| `offerId` | Selected offer identifier. |
| `price` and `currency` | Offer price together with its currency. |
| `labels` | Individual labels using their configured backgrounds, if any. |
| `providerName` | Optional provider information for operators. |

Provide Edit and Delete actions for each row. Provide a drag handle to change the saved order. Display a clear empty state when the response contains no saved packs.

The response does not contain saved live booleans. Do not invent saved live indicators or recalculate them in the browser from the date snapshots. Display the server's comparison messages for validity differences.

### Warnings and check errors

Display `messages` in a warning area above the saved-pack table. Use `packId` to associate each warning with its row, and display the server-provided `message` text.

The checks cover:

- Differences in the computed live states of the pack, selected offer, and selected pack-offer association.
- A saved pack or selected offer that can no longer be found on Atom.
- Missing or ambiguous pack-offer associations.
- A different numeric price for the selected offer. The warning text includes currency; a currency-only change currently does not trigger this warning.

The comparison does not update the database. The operator reviews the affected configuration and saves it to accept the current Atom values.

Display `errors` separately from comparison warnings. An Atom failure can return HTTP 200 with `ok: true`, saved `packs`, and entries in `errors`. Keep the saved table visible in that case. Do not interpret an unavailable Atom response as evidence that packs are missing.

A database failure returns an unsuccessful response with `ok: false` and `error`. Show the failure and allow the operator to retry.

## 4. Opening Add new pack or Edit

Open a single editor popup and request fresh Atom choices:

```json
{
  "mode": "packs",
  "atom_product_id": 2883
}
```

This mode reads Atom data and returns:

```json
{
  "ok": true,
  "packs": [
    {
      "id": "32811",
      "name": "Example pack",
      "validityStart": null,
      "validityEnd": null,
      "validityTz": "UTC",
      "live": true,
      "offers": [
        {
          "id": "9981",
          "name": "Example offer",
          "providerId": "7",
          "provider": "Example provider",
          "price": 4.99,
          "currency": "EUR",
          "validityStart": null,
          "validityEnd": "2099-01-01 00:00:00",
          "validityTz": "UTC",
          "live": true,
          "packOffer": {
            "id": "association-1",
            "used": null,
            "data": null,
            "validityStart": null,
            "validityEnd": "2099-01-01 00:00:00",
            "validityTz": "UTC",
            "live": true
          }
        }
      ]
    }
  ]
}
```

The example values are illustrative. Pack, offer, provider, and association IDs are strings. The requested Atom product ID is numeric.

### Pack and offer dropdowns

Show both dropdowns inside the editor popup. Selecting a pack must not open another modal.

For the pack dropdown, display the pack name and ID. For the offer dropdown, display the offer name, ID, price, currency, and any provider information needed by the operator.

Group choices by the `live` value supplied by the edge function:

1. `true`: live choices first.
2. `false`: non-live choices next.
3. `null`: unknown validity last.

Preserve Atom's order within each group. Offer choices must belong to the selected pack.

### Validity chips

Display live information in a chip on the same row as the ID, aligned to the right:

- `live: true`: green chip.
- `live: false`: red chip.
- `live: unknown`: neutral chip.
- When `validityEnd` is present, append `end date: DD/MM/YYYY`.

For an offer, show separate chips for the offer and its pack-offer association so their states are distinguishable. A null end date can be represented by a live chip without an end date.

Use only day, month, and year in the displayed end date. Preserve the original Atom timestamp and timezone when saving. Do not convert the displayed calendar date through the browser's timezone.

### Editing an existing selection

Restore the saved pack and its exact offer/association pair after the Atom response arrives. An offer can have multiple pack-offer associations; use both `offer.id` and `packOffer.id` to identify the selected choice.

If a saved association is missing, show that it needs to be selected again. If a legacy record has no `packOfferId` and multiple associations match, require an explicit choice rather than guessing.

Ignore an editor response if the popup has been closed or a newer editor request has started.

## 5. Understanding live states

The edge function computes `live` from the end date. The backoffice uses that result for ordering and chip appearance.

| Atom date information | Result |
| --- | --- |
| Null end date or `infinity` | `live: true`. |
| `-infinity` | `live: false`. |
| Valid end date | Live while the current instant is earlier than the end. The end is exclusive. |
| Invalid date or unusable timezone information | `live: null`. |

Explicit offsets are respected. A timestamp without an offset is evaluated in its declared IANA timezone, including daylight-saving rules. Start dates do not determine this live flag.

The saved-versus-Atom comparison uses the same validity calculation for both sets of dates. These checks belong to the edge function, not to the UI.

## 6. Editable fields and labels

The editor should contain:

- Pack and offer dropdowns populated from Atom.
- An editable display name, saved as `packName`.
- An editable positive integer pack value, saved as `value`.
- Read-only offer price and currency from Atom.
- A list of Label and Color controls, with a `+` action to add rows and a remove action for each row.
- A preview of the configured title, value, price, and labels.

Build the JSON label array from the controls when saving. Operators should not have to type JSON. Ignore empty label rows.

### Label color format

The `labels` column contains a JSON array:

```json
[
  { "label": "Starter pack", "color": null },
  {
    "label": "Special",
    "color": { "type": "solid", "value": "#6650CF" }
  },
  {
    "label": "Most popular",
    "color": {
      "type": "linear-gradient",
      "colors": ["#65CAD7", "#058AC4"],
      "locations": [0, 1],
      "start": { "x": 0, "y": 0.5 },
      "end": { "x": 1, "y": 0.5 }
    }
  }
]
```

A missing or null `color` means no background. A solid color uses `value`. A gradient uses at least two colors, an equally sized array of ordered locations between 0 and 1, and distinct start/end points with coordinates between 0 and 1.

### Color controls and preview

Use `react-best-gradient-color-picker` for the web editor, with solid and linear-gradient modes and a white background. Show color-only preset swatches, a No background option, and a button to open the custom picker. Preset names must not become label text automatically.

Render one pill per label. Apply the received solid color or gradient to that pill's background. Without a color, display plain text without a pill background. When there are no labels, use `packName` as the preview title.

Distribute multiple labels across the available row width, with the first and last at opposite edges inside the card padding. Allow wrapping when necessary.

For gradients, preserve color-stop positions, opacity, and direction. A CSS angle must be adjusted for the element's aspect ratio when converted to native gradient control points; use the existing `LabelGradient` implementation for consistent rendering.

## 7. Saving a configuration

Construct the record from the editor and the selected Atom objects:

```ts
const record = {
  productId: atomProductId,
  packId: selectedPack.id,
  packName: displayName.trim(),
  value: packValue,
  labels,
  sortOrder,
  packValidityEnd: selectedPack.validityEnd,
  packValidityTz: selectedPack.validityTz,
  offerValidityEnd: selectedOffer.validityEnd,
  offerValidityTz: selectedOffer.validityTz,
  packOfferValidityEnd: selectedOffer.packOffer.validityEnd,
  packOfferValidityTz: selectedOffer.packOffer.validityTz,
  packOfferId: selectedOffer.packOffer.id,
  offerId: selectedOffer.id,
  price: selectedOffer.price,
  currency: selectedOffer.currency,
  providerName: selectedOffer.provider,
};

const { data, error } = await supabase
  .from('product_packs')
  .upsert(record, { onConflict: 'productId,packId' })
  .select('*')
  .single();

if (error) throw error;
```

Validate the display name, a positive integer value, a selected offer, a nonnegative finite price, valid label data, and the provider name required by the current save contract.

Persist the original Atom end dates and timezones. Do not persist computed `live` values, expired booleans, `providerId`, or an additional offer-title field. `packName` is the existing editable title.

`product_packs` and `reorder_product_packs` live in the `backoffice` schema, the default schema of the backoffice Supabase client, so the calls below need no `.schema()`.

The primary key is `(productId, packId)`. A product may have several packs; multiple saved configurations for the same product/pack with different offers are not currently supported.

Preserve `sortOrder` when editing. Append new packs after the largest current position. On success, update the table with the returned row, close the editor, and display confirmation. On failure, keep the editor open with the operator's inputs and show the error.

The comparison does not automatically acknowledge or overwrite changes. Saving is the operator's explicit acceptance of the current Atom snapshot.

## 8. Deleting a configuration

Ask the operator to confirm the deletion, then scope the operation by both keys:

```ts
const { error } = await supabase
  .from('product_packs')
  .delete()
  .eq('productId', atomProductId)
  .eq('packId', selectedPackId)
  .select('packId')
  .single();

if (error) throw error;
```

This removes the saved database configuration, not the Atom resource. Remove the visible row only after success. A permission failure or zero-row result must not be shown as a successful deletion.

## 9. Reordering the saved table

Allow the operator to drag rows using a handle. Up/down controls can provide an additional accessible way to move a row.

Persist the complete ordered list for the current Atom product in one RPC call:

```ts
const { error } = await supabase.rpc('reorder_product_packs', {
  p_product_id: atomProductId,
  p_pack_ids: orderedPackIds,
});

if (error) throw error;
```

The RPC updates positions atomically under the caller's permissions. It rejects duplicate IDs, incomplete or mismatching lists, and operations that do not update all expected rows.

Show the new order immediately if using optimistic updates, indicate that it is being saved, and restore the previous order on failure. Prevent conflicting writes while saving the order. Reordering does not call Atom.

## 10. Discontinue `get-atom-legal-document`

The legacy `get-atom-legal-document` endpoint is discontinued for backoffice integrations. Replace its callers with the `atom` Edge Function. Legal-document discovery and HTML retrieval now use the same Atom integration as the pack editor.

### Request migration

| Previous request | Replacement |
| --- | --- |
| `POST /functions/v1/get-atom-legal-document`, `mode: "discover"` | `POST /functions/v1/atom`, `mode: "discover"`. |
| `POST /functions/v1/get-atom-legal-document`, `mode: "document"` | `POST /functions/v1/atom`, `mode: "documents"`. |

The retrieval mode changes from singular **`document`** to plural **`documents`**. Always send the mode explicitly. Pass the numeric `atom_product_id`, the intended `language`, and, for retrieval, the discovered `format`. An optional `date` selects the document date; without it the function uses the current UTC date.

### Discover available documents

```ts
const { data, error } = await supabase.functions.invoke('atom', {
  body: {
    mode: 'discover',
    atom_product_id: atomProductId,
    language: selectedLanguage,
  },
});

if (error) throw error;
if (!data || data.ok !== true) {
  throw new Error(data?.error ?? 'Unable to discover Atom documents.');
}
```

The response contains:

```ts
{
  ok: true;
  requestedLanguage: string;
  documents: {
    id: string;
    name: string;
    sourceDocumentFormat: string;
    documentFormat: string;
  }[];
  formatsDiscovered: string[];
}
```

Display `name` in the document selector. Use the selected entry's `documentFormat` as the retrieval request's `format`; do not use the display name, `sourceDocumentFormat`, or document ID for that parameter. Discovery lists the Atom product's document metadata; `requestedLanguage` echoes the requested language and does not guarantee that every listed document can be retrieved in that language.

### Retrieve and display document HTML

```ts
const { data, error } = await supabase.functions.invoke('atom', {
  body: {
    mode: 'documents',
    atom_product_id: atomProductId,
    language: selectedLanguage,
    format: selectedDocument.documentFormat,
  },
});

if (error) throw error;
if (!data || data.ok !== true) {
  throw new Error(data?.error ?? 'Unable to load the Atom document.');
}

const html = data.document.body_html;
```

By default the response is:

```ts
{
  ok: true;
  document: {
    slug: string;
    locale: string;
    body_html: string;
    updated_at: string;
  };
}
```

Render `body_html` in the backoffice document preview using its HTML-rendering policy. Keep the document title and selected language visible. Show loading and retrieval-error states within the preview area. Clear or replace the previous preview when the product, document, or language changes, and ignore stale responses.

If using a direct HTTP request with `Accept: text/html`, the same `documents` mode returns raw HTML with `Content-Type: text/html; charset=utf-8` instead of the JSON envelope. Parse that response as text, not JSON. The response's `updated_at` is generated at retrieval time; it is not an Atom document revision timestamp.

Both modes default to `fr` when language is omitted, so pass the language selected in the interface explicitly. Reuse the backoffice request authentication configuration; Atom credentials remain on the server.

Remove calls and wrappers targeting the legacy endpoint after migrating document selectors and previews. Do not rely on an automatic redirect or a `document` mode alias: the current `atom` function accepts `documents`.

`get-atom-legal-document` is no longer shipped by backoffice-edge. A project where it is still deployed keeps the old copy until it is deleted (`supabase functions delete get-atom-legal-document`); delete it only after its callers use `atom`.

## 11. Implementation references

| File | Use it for |
| --- | --- |
| [`supabase/functions/atom/index.ts`](../supabase/functions/atom/index.ts) | Request parameters and exported response interfaces. |
| [`supabase/functions/atom/pack-checks.ts`](../supabase/functions/atom/pack-checks.ts) | Validity rules and saved-versus-Atom warning behavior. |
| [`supabase/functions/_shared/atom/packs.ts`](../supabase/functions/_shared/atom/packs.ts) | Atom pack retrieval and date extraction. |
| [`supabase/migrations/20261107150000_product_packs.sql`](../supabase/migrations/20261107150000_product_packs.sql) | Database schema (`backoffice` schema), label validation, RLS policies, and reorder RPC. |
| [`supabase/functions/get-product-packs/index.ts`](../supabase/functions/get-product-packs/index.ts) | App-facing read of the saved packs (Buy Votes), no login required. |

Keep the UI synchronized with these response contracts. In particular, distinguish a successful response containing check errors from an unsuccessful request, and always retain the configured Atom product scope in reads and writes.

## 12. Deploy

Secrets (same as the legacy legal-document function): `ATOM_BASE_URL` (optional, defaults to `https://atom.digitalvirgo.com`), `ATOM_USER`, `ATOM_SDK_ACCESS_KEY`.

`atom` imports the private `@digitalvirgo/atom-api` package: deploy it with a `supabase/functions/atom/.npmrc` holding the registry token (never committed, never synced, same as `pulsar`). Tests use `supabase/tests/stubs/atom-api.ts` instead.

```bash
supabase functions deploy atom --no-verify-jwt --project-ref <project-ref>
supabase functions deploy get-product-packs --no-verify-jwt --project-ref <project-ref>
```
