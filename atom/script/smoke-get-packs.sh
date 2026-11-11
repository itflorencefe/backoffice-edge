#!/usr/bin/env bash
# Optional: ATOM_PRODUCT_ID, OUT_FILE.
set -euo pipefail
ATOM_PRODUCT_ID="${ATOM_PRODUCT_ID:-2883}"
source "$(cd "$(dirname "$0")" && pwd)/smoke-atom-common.sh"
BODY=$(jq -n --argjson product "$PRODUCT_ID" '{mode:"packs", atom_product_id:$product}')
atom_post "$BODY"
if ! jq -e '
  def valid_dates:
    (.validityStart | . == null or type == "string")
    and (.validityEnd | . == null or type == "string")
    and (.validityTz | . == null or type == "string")
    and (.live | . == null or type == "boolean");
  keys == ["ok", "packs"]
  and (.packs | type == "array")
  and ([.packs[].id] | length == (unique | length))
  and all(.packs[];
    keys == ["id", "live", "name", "offers", "validityEnd", "validityStart", "validityTz"]
    and valid_dates
    and (.id | type == "string" and test("\\S"))
    and (.name | . == null or type == "string")
    and (.offers | type == "array")
    and all(.offers[];
      keys == ["currency", "id", "live", "name", "packOffer", "price", "provider", "providerId", "validityEnd", "validityStart", "validityTz"]
      and valid_dates
      and (.id | type == "string" and test("\\S"))
      and (.providerId | . == null or (type == "string" and test("\\S")))
      and (.name | . == null or type == "string")
      and (.provider | . == null or type == "string")
      and (.price | . == null or type == "number")
      and (.currency | . == null or (type == "string" and test("\\S")))
      and (.packOffer |
        type == "object"
        and keys == ["data", "id", "live", "used", "validityEnd", "validityStart", "validityTz"]
        and valid_dates
        and (.id | . == null or (type == "string" and test("\\S")))
        and (.used | . == null or type == "boolean")
        and (.data | . == null or type == "object")
      )
    )
  )
' "$TMP" >/dev/null; then
  cat "$TMP" >&2
  echo 'FAIL: expected unique pack IDs, offer IDs/providerId, packOffer and validityStart/validityEnd/validityTz/live on packs, offers and packOffer' >&2
  exit 1
fi
if [[ -n "${OUT_FILE:-}" ]]; then
  jq '{packs}' "$TMP" > "$OUT_FILE"
  echo "Wrote: $OUT_FILE"
else
  jq . "$TMP"
fi
echo 'PASS: packs response is valid (empty results are allowed)'
