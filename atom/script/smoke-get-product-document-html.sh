#!/usr/bin/env bash
# Local defaults can optionally be overridden through environment variables.
# Optional: DOCUMENT_DATE, OUT_FILE.
set -euo pipefail
ATOM_PRODUCT_ID="${ATOM_PRODUCT_ID:-2930}"
LANGUAGE="${LANGUAGE:-fr}"
DOCUMENT_FORMAT="${DOCUMENT_FORMAT:-data_privacy}"
source "$(cd "$(dirname "$0")" && pwd)/smoke-atom-common.sh"
BODY=$(jq -n --argjson product "$PRODUCT_ID" --arg language "$LANGUAGE" \
  --arg format "$DOCUMENT_FORMAT" --arg date "${DOCUMENT_DATE:-}" '
  {mode:"documents",atom_product_id:$product,language:$language,format:$format}
  + (if $date == "" then {} else {date:$date} end)')
atom_post "$BODY"
EXPECTED_LANGUAGE=$(jq -rn --arg value "$LANGUAGE" '$value | ascii_downcase')
EXPECTED_FORMAT=$(jq -rn --arg value "$DOCUMENT_FORMAT" '$value | gsub("^\\s+|\\s+$"; "")')
if ! jq -e --arg language "$EXPECTED_LANGUAGE" --arg format "$EXPECTED_FORMAT" '
  .document.slug == $format and .document.locale == $language
  and (.document.body_html | type == "string" and length > 0)
  and (.document.updated_at | type == "string")
' "$TMP" >/dev/null; then
  cat "$TMP" >&2
  echo 'FAIL: expected a matching document with non-empty HTML' >&2
  exit 1
fi
if [[ -n "${OUT_FILE:-}" ]]; then
  jq -jr '.document.body_html' "$TMP" > "$OUT_FILE"
  echo "Wrote: $OUT_FILE"
else
  echo 'Preview (first 500 characters):'
  jq -r '.document.body_html[:500]' "$TMP"
fi
echo 'PASS: documents returned non-empty HTML'
