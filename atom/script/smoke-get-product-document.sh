#!/usr/bin/env bash
# Local defaults can optionally be overridden through environment variables.
set -euo pipefail
ATOM_PRODUCT_ID="${ATOM_PRODUCT_ID:-2930}"
LANGUAGE="${LANGUAGE:-fr}"
source "$(cd "$(dirname "$0")" && pwd)/smoke-atom-common.sh"
BODY=$(jq -n --argjson product "$PRODUCT_ID" --arg language "$LANGUAGE" \
  '{mode:"discover",atom_product_id:$product,language:$language}')
atom_post "$BODY"
EXPECTED_LANGUAGE=$(jq -rn --arg value "$LANGUAGE" '$value | ascii_downcase')
if ! jq -e --arg language "$EXPECTED_LANGUAGE" '
  .requestedLanguage == $language
  and (.documents | type == "array")
  and (.formatsDiscovered | type == "array")
  and all(.documents[]; (.id | type == "string") and (.name | type == "string")
    and (.sourceDocumentFormat | type == "string") and (.documentFormat | type == "string"))
' "$TMP" >/dev/null; then
  echo 'FAIL: invalid discovery response' >&2
  cat "$TMP" >&2
  exit 1
fi
jq . "$TMP"
echo 'PASS: discover returned a valid catalog'
