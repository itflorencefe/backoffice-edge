#!/usr/bin/env bash
# Optional: ATOM_PRODUCT_ID, INCLUDE (comma-separated relationships), OUT_FILE.
set -euo pipefail
ATOM_PRODUCT_ID="${ATOM_PRODUCT_ID:-2883}"
source "$(cd "$(dirname "$0")" && pwd)/smoke-atom-common.sh"
BODY=$(jq -n --argjson product "$PRODUCT_ID" --arg include "${INCLUDE:-}" '
  {mode:"product", atom_product_id:$product}
  + (if $include == "" then {} else {include:$include} end)')
atom_post "$BODY"
if ! jq -e '
  (.product | has("offers")) as $offers
  | (.product | has("legalDocuments")) as $legal
  | (.product | has("included")) as $included
  | (.product | type == "object")
  and (.product | keys == (["emailSupport", "phoneSupport", "smsPhoneSupport", "snowplowId"]
    + (if $offers then ["offers"] else [] end)
    + (if $legal then ["legalDocuments"] else [] end)
    + (if $included then ["included"] else [] end) | sort))
  and all(.product | .snowplowId, .phoneSupport, .emailSupport, .smsPhoneSupport;
    . == null or type == "string")
  and (if $included then
    (.product.included | type == "array") and all(.product.included[]; type == "object")
  else true end)
  and (if $legal then
    (.product.legalDocuments | type == "array")
    and all(.product.legalDocuments[];
      type == "object" and has("id"))
  else true end)
  and (if $offers then
    (.product.offers | type == "array")
    and all(.product.offers[];
      type == "object" and has("id"))
  else true end)
' "$TMP" >/dev/null; then
  echo 'FAIL: expected ProductDto with support fields and optional raw offer/legal document arrays' >&2
  exit 1
fi
if [[ -n "${OUT_FILE:-}" ]]; then
  jq '.product' "$TMP" > "$OUT_FILE"
  echo "Wrote: $OUT_FILE"
else
  jq . "$TMP"
fi
echo 'PASS: product response is valid'
