#!/usr/bin/env bash
# Shared helpers for the Atom edge smoke tests, with local development defaults.
set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
LOCAL_SUPABASE=false
case "${SUPABASE_URL%/}" in
  http://127.0.0.1:54321|http://localhost:54321) LOCAL_SUPABASE=true ;;
esac

command -v curl >/dev/null || { echo "FAIL: curl required" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required" >&2; exit 1; }

resolve_anon_key() {
  if [[ -n "${SUPABASE_ANON_KEY:-}" ]]; then
    printf '%s' "$SUPABASE_ANON_KEY"
    return
  fi
  if [[ -n "${SUPABASE_PUBLISHABLE_KEY:-}" ]]; then
    printf '%s' "$SUPABASE_PUBLISHABLE_KEY"
    return
  fi
  if [[ "$LOCAL_SUPABASE" != true ]]; then
    echo 'FAIL: remote projects require SUPABASE_ANON_KEY or SUPABASE_PUBLISHABLE_KEY' >&2
    return 1
  fi
  if command -v supabase >/dev/null; then
    local key repo_root
    repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    key=$(cd "$repo_root" && supabase status -o json 2>/dev/null | jq -r \
      '.ANON_KEY // .anon_key // .publishable_key // empty' || true)
    if [[ -n "$key" && "$key" != "null" ]]; then
      printf '%s' "$key"
      return
    fi
  fi
  printf '%s' 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'
}

SUPABASE_ANON_KEY="$(resolve_anon_key)"
PRODUCT_ID=$(jq -en --arg value "$ATOM_PRODUCT_ID" '$value | tonumber | select(isfinite)') || {
  echo "FAIL: ATOM_PRODUCT_ID must be numeric" >&2
  exit 1
}
FN="${SUPABASE_URL%/}/functions/v1/atom"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

resolve_access_token() {
  if [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
    return
  fi
  if [[ "$LOCAL_SUPABASE" == true && -z "${SUPABASE_EMAIL:-}${SUPABASE_PASSWORD:-}" ]]; then
    SUPABASE_EMAIL='atom-smoke@example.test'
    SUPABASE_PASSWORD='AtomSmoke-local-only-2026!'
  fi
  if [[ -z "${SUPABASE_EMAIL:-}" || -z "${SUPABASE_PASSWORD:-}" ]]; then
    echo 'FAIL: set SUPABASE_ACCESS_TOKEN or both SUPABASE_EMAIL and SUPABASE_PASSWORD' >&2
    exit 1
  fi
  local payload status
  payload=$(jq -n --arg email "$SUPABASE_EMAIL" --arg password "$SUPABASE_PASSWORD" \
    '{email:$email,password:$password}')
  status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    -w '%{http_code}' -o "$TMP" -X POST "${SUPABASE_URL%/}/auth/v1/token?grant_type=password" \
    -H 'Content-Type: application/json' -H "apikey: $SUPABASE_ANON_KEY" \
    --data "$payload") || { echo 'FAIL: Supabase login request failed' >&2; exit 1; }
  if [[ "$status" != 200 ]]; then
    echo "FAIL: Supabase login returned HTTP $status; apply atom/script/local-smoke-user.sql to the local stack or check your credentials" >&2
    exit 1
  fi
  SUPABASE_ACCESS_TOKEN=$(jq -er '.access_token | select(type == "string" and length > 0)' "$TMP") || {
    echo 'FAIL: Supabase login did not return an access token' >&2
    exit 1
  }
}

resolve_access_token

atom_post() {
  local payload="$1"
  HTTP=$(curl --silent --show-error --connect-timeout 10 --max-time 60 \
    -w '%{http_code}' -o "$TMP" -X POST "$FN" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    --data "$payload") || { echo "FAIL: request failed" >&2; exit 1; }
  echo "URL: $FN"
  echo "HTTP: $HTTP"
  if [[ "$HTTP" != "200" ]]; then
    cat "$TMP" >&2
    echo "FAIL: expected HTTP 200" >&2
    exit 1
  fi
  if ! jq -e 'type == "object" and .ok == true' "$TMP" >/dev/null; then
    cat "$TMP" >&2
    echo "FAIL: expected JSON object with ok:true" >&2
    exit 1
  fi
}
