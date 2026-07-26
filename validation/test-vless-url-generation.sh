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
      "settings": {
        "clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"mode": "stream-one", "path": "/xhttp-test"},
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
          "fingerprint": "chrome",
          "shortIds": ["abcd1234"]
        }
      }
    },
    {
      "port": 12346,
      "settings": {
        "clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}],
        "decryption": "mlkem768x25519plus.native.test-decryption"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"mode": "stream-one", "path": "/xhttp-pq"},
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
          "fingerprint": "chrome",
          "shortIds": ["beef5678"]
        }
      }
    },
    {
      "port": 23456,
      "settings": {
        "clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {"serviceName": "svc-test"},
        "realitySettings": {
          "serverNames": ["www.cloudflare.com"],
          "fingerprint": "chrome",
          "shortIds": ["feed9876"]
        }
      }
    },
    {
      "port": 34567,
      "settings": {
        "clients": [{"id": "77777777-7777-4777-8777-777777777777", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"mode": "stream-one", "path": ""},
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
          "fingerprint": "chrome",
          "shortIds": ["cafe9876"]
        }
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

cat > "$PROFILES_DIR/stale-metadata.json" <<'JSON'
{
  "name": "stale-metadata",
  "uuid": "11111111-2222-3333-4444-555555555555",
  "routes": [
    {
      "label": "xhttp-legacy",
      "transport": "xhttp",
      "port": 12345,
      "sni": "stale.example.com",
      "fingerprint": "firefox",
      "xhttp_path": "/xhttp-stale"
    }
  ]
}
JSON

stale_metadata_urls=$(_generate_vless_urls_for_profile "$PROFILES_DIR/stale-metadata.json") \
  || fail "live metadata URL generation failed"
grep -q 'sni=www.ozon.ru' <<< "$stale_metadata_urls" || fail "URL generation must use live inbound SNI"
grep -q 'fp=chrome' <<< "$stale_metadata_urls" || fail "URL generation must use live inbound fingerprint"
grep -q 'type=xhttp&path=%2Fxhttp-test&mode=stream-one#stale-metadata-xhttp-legacy' <<< "$stale_metadata_urls" \
  || fail "URL generation must use live inbound XHTTP path"

cat > "$PROFILES_DIR/missing-client.json" <<'JSON'
{
  "name": "missing-client",
  "uuid": "99999999-9999-4999-8999-999999999999",
  "routes": [
    {
      "label": "xhttp-legacy",
      "transport": "xhttp",
      "port": 12345,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "xhttp_path": "/xhttp-test"
    }
  ]
}
JSON

if _generate_vless_urls_for_profile "$PROFILES_DIR/missing-client.json" > "$WORKDIR/missing-client.out"; then
  fail "URL generation must reject routes whose UUID is absent from live inbound clients"
fi
[[ ! -s "$WORKDIR/missing-client.out" ]] || fail "missing-client URL output must be empty"

cat > "$PROFILES_DIR/empty-live-xhttp-path.json" <<'JSON'
{
  "name": "empty-live-xhttp-path",
  "uuid": "77777777-7777-4777-8777-777777777777",
  "routes": [
    {
      "label": "xhttp-legacy",
      "transport": "xhttp",
      "port": 34567,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "xhttp_path": "/xhttp-profile-only"
    }
  ]
}
JSON

if _generate_vless_urls_for_profile "$PROFILES_DIR/empty-live-xhttp-path.json" > "$WORKDIR/empty-live-xhttp-path.out"; then
  fail "URL generation must reject XHTTP routes whose live inbound path is empty"
fi
[[ ! -s "$WORKDIR/empty-live-xhttp-path.out" ]] || fail "empty-live-xhttp-path URL output must be empty"

echo "✓ VLESS URL generation checks passed"
