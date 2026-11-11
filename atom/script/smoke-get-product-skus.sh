#!/usr/bin/env bash
# Local defaults can optionally be overridden through environment variables.
set -euo pipefail
ATOM_PRODUCT_ID="${ATOM_PRODUCT_ID:-2883}"
PLATFORM="${PLATFORM:-appstore}"
source "$(cd "$(dirname "$0")" && pwd)/smoke-atom-common.sh"
NORMALIZED_PLATFORM=$(jq -rn --arg value "$PLATFORM" '$value | gsub("^\\s+|\\s+$"; "") | ascii_downcase')
[[ -n "$NORMALIZED_PLATFORM" ]] || { echo 'FAIL: PLATFORM must not be blank' >&2; exit 1; }
BODY=$(jq -n --argjson product "$PRODUCT_ID" --arg platform "$PLATFORM" \
  '{mode:"skus",atom_product_id:$product,platform:$platform}')
atom_post "$BODY"
if ! jq -e --argjson product "$PRODUCT_ID" --arg platform "$NORMALIZED_PLATFORM" '
  .atom_product_id == $product and .platform == $platform
  and (.offer_count | type == "number" and . >= 0 and floor == .)
  and (.sku_count | type == "number" and . >= 0 and floor == .)
  and (.skus | type == "array")
  and .sku_count == (.skus | length)
  and ([.skus[].id] | length == (unique | length))
  and all(.skus[];
    keys == ["external_id", "id", "name", "price", "units"]
    and (.id | type == "string" and length > 0)
    and (.name | type == "string")
    and (.external_id | . == null or type == "string")
    and (.price | . == null or type == "number")
    and (.units | . == null or type == "number")
  )
' "$TMP" >/dev/null; then
  cat "$TMP" >&2
  echo 'FAIL: expected SKU DTO fields (id, name, external_id, price, units), valid counts and unique ids' >&2
  exit 1
fi
jq . "$TMP"
echo 'PASS: SKU response is valid (empty results are allowed)'
