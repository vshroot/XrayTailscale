#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/xraytailscale"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq 'HAPP_SERVER_NAME="${HAPP_SERVER_NAME:-}"' "$SCRIPT" ||
  fail "subhttp runtime fallback for HAPP_SERVER_NAME is missing"
grep -Fq 'subscription_title="${HAPP_SERVER_NAME:-}"' "$SCRIPT" ||
  fail "subscription title does not use HAPP_SERVER_NAME"
grep -Fq 'subscription_title="$profile_name"' "$SCRIPT" ||
  fail "profile-name backward-compatible fallback is missing"
grep -Fq 'HAPP_SERVER_NAME=""' "$SCRIPT" ||
  fail "default HAPP_SERVER_NAME setting is missing"
grep -Fq '_happ_edit_field "$env_file" "HAPP_SERVER_NAME"' "$SCRIPT" ||
  fail "HAPP settings menu cannot edit server name"
grep -Fq 'subscription handler регенерирован' "$SCRIPT" ||
  fail "handler regeneration after settings update is missing"

echo "PASS: custom HAPP subscription server name"
