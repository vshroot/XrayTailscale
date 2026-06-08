#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "Проверка генерации VLESS URLs"

WORKDIR=$(mktemp -d /tmp/xraytailscale-urlgen.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
PUBLIC_KEY_FILE="$WORKDIR/.public_key"
VLESS_ENCRYPTION_FILE="$WORKDIR/.vless_encryption"
SERVER_IP="203.0.113.10"

mkdir -p "$PROFILES_DIR"
printf '%s' 'test-public-key' > "$PUBLIC_KEY_FILE"
printf '%s' 'mlkem768x25519plus.native.test-encryption' > "$VLESS_ENCRYPTION_FILE"

cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 12345,
      "streamSettings": {
        "network": "xhttp",
        "realitySettings": {"shortIds": ["abcd1234"]}
      }
    },
    {
      "port": 12346,
      "streamSettings": {
        "network": "xhttp",
        "realitySettings": {"shortIds": ["beef5678"]}
      }
    },
    {
      "port": 23456,
      "streamSettings": {
        "network": "grpc",
        "realitySettings": {"shortIds": ["feed9876"]}
      }
    }
  ]
}
JSON

cat > "$PROFILES_DIR/sample.json" <<'JSON'
{
  "name": "sample",
  "uuid": "11111111-2222-3333-4444-555555555555",
  "routes": [
    {
      "label": "xhttp-legacy",
      "transport": "xhttp",
      "port": 12345,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "xhttp_path": "/xhttp-test"
    },
    {
      "label": "xhttp-pq",
      "transport": "xhttp",
      "port": 12346,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "pq_enabled": true,
      "xhttp_path": "/xhttp-pq"
    },
    {
      "label": "grpc",
      "transport": "grpc",
      "port": 23456,
      "sni": "www.cloudflare.com",
      "fingerprint": "chrome",
      "grpc_service_name": "svc-test"
    }
  ]
}
JSON

urls=$(_generate_vless_urls_for_profile "$PROFILES_DIR/sample.json") || fail "URL generation failed"

grep -q 'sample-xhttp-legacy' <<< "$urls" || fail "legacy XHTTP route missing"
grep -q 'encryption=none' <<< "$urls" || fail "legacy XHTTP must use encryption=none"
grep -q 'type=xhttp&path=%2Fxhttp-test&mode=stream-one#sample-xhttp-legacy' <<< "$urls" || fail "legacy XHTTP URL must include mode=stream-one and encoded path"
grep -q 'encryption=mlkem768x25519plus.native.test-encryption' <<< "$urls" || fail "PQ XHTTP encryption missing"
grep -q 'type=xhttp&path=%2Fxhttp-pq&mode=stream-one#sample-xhttp-pq' <<< "$urls" || fail "PQ XHTTP URL must include mode=stream-one"
! grep -q '&host=' <<< "$urls" || fail "XHTTP URLs must not force Host header"
grep -q 'type=grpc&serviceName=svc-test&mode=gun#sample-grpc' <<< "$urls" || fail "gRPC URL must include mode=gun"

echo "✓ VLESS URL generation checks passed"
