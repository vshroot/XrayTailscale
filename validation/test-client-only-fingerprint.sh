#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

file_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

WORKDIR=$(mktemp -d /tmp/xraytailscale-client-fingerprint.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
PUBLIC_KEY_FILE="$WORKDIR/.public_key"
VLESS_ENCRYPTION_FILE="$WORKDIR/.vless_encryption"
SERVER_IP="203.0.113.10"

mkdir -p "$PROFILES_DIR"
printf '%s' 'public-test-key' > "$PUBLIC_KEY_FILE"
printf '%s' 'mlkem768x25519plus.native.test-encryption' > "$VLESS_ENCRYPTION_FILE"

[[ "${DEFAULT_CLIENT_FINGERPRINT:-}" == "firefox" ]] \
  || fail "default client fingerprint must be firefox"

cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 12345,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
          "fingerprint": "chrome",
          "shortIds": ["abcd1234"]
        }
      }
    },
    {
      "port": 12346,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
          "fingerprint": "chrome",
          "shortIds": ["beef5678"]
        }
      }
    },
    {
      "port": 12347,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "22222222-2222-4222-8222-222222222222", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
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
  "port": 12345,
  "fingerprint": "chrome",
  "routes": [
    {
      "label": "tcp-vision",
      "transport": "tcp",
      "port": 12345,
      "sni": "stale.example.com",
      "fingerprint": "chrome"
    },
    {
      "label": "tcp-mux",
      "transport": "tcp-mux",
      "port": 12346,
      "sni": "www.ozon.ru",
      "fingerprint": "safari"
    }
  ]
}
JSON

cat > "$PROFILES_DIR/default.json" <<'JSON'
{
  "name": "default",
  "uuid": "22222222-2222-4222-8222-222222222222",
  "port": 12347,
  "transport": "tcp",
  "sni": "www.ozon.ru"
}
JSON

default_url=$(_generate_vless_url_pure "$PROFILES_DIR/default.json") \
  || fail "default URL generation failed"
[[ "$default_url" == *"&fp=firefox&"* ]] \
  || fail "missing profile fingerprint must fall back to firefox"

route_url=$(_generate_vless_url_pure "$PROFILES_DIR/sample.json" 0) \
  || fail "route URL generation failed"
[[ "$route_url" == *"sni=www.ozon.ru"* ]] \
  || fail "URL generation must still repair stale profile SNI from live inbound"
[[ "$route_url" == *"&fp=chrome&"* ]] \
  || fail "existing explicit Chrome profile fingerprint must be preserved"

update_profile_fingerprint "$PROFILES_DIR/sample.json" 0 firefox \
  || fail "primary route fingerprint update failed"
updated_url=$(_generate_vless_url_pure "$PROFILES_DIR/sample.json" 0) \
  || fail "updated route URL generation failed"
[[ "$updated_url" == *"&fp=firefox&"* ]] \
  || fail "subscription URL must use profile route fingerprint, not live inbound fingerprint"
[[ "$(jq -r '.fingerprint' "$PROFILES_DIR/sample.json")" == "firefox" ]] \
  || fail "primary route update must keep top-level fingerprint mirror in sync"

config_before=$(file_hash "$CONFIG_FILE")
update_profile_fingerprint "$PROFILES_DIR/sample.json" 1 edge \
  || fail "secondary route fingerprint update failed"
config_after=$(file_hash "$CONFIG_FILE")
[[ "$config_before" == "$config_after" ]] \
  || fail "client fingerprint update must not modify config.json"
[[ "$(jq -r '.routes[0].fingerprint' "$PROFILES_DIR/sample.json")" == "firefox" ]] \
  || fail "secondary route update changed primary route"
[[ "$(jq -r '.routes[1].fingerprint' "$PROFILES_DIR/sample.json")" == "edge" ]] \
  || fail "secondary route fingerprint was not stored"

profile_before=$(file_hash "$PROFILES_DIR/sample.json")
if update_profile_fingerprint "$PROFILES_DIR/sample.json" 9 firefox 2>/dev/null; then
  fail "missing route update unexpectedly succeeded"
fi
profile_after=$(file_hash "$PROFILES_DIR/sample.json")
[[ "$profile_before" == "$profile_after" ]] \
  || fail "failed route update modified the profile"

_remove_ignored_reality_server_fingerprints "$CONFIG_FILE" \
  || fail "legacy server-side fingerprints were not removed"
! jq -e 'any(.inbounds[]?; ((.streamSettings.realitySettings? // {}) | has("fingerprint")))' \
  "$CONFIG_FILE" >/dev/null \
  || fail "server-side fingerprint survived cleanup"

cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 12345,
      "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision"}]},
      "streamSettings": {
        "network": "tcp",
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
          "fingerprint": "chrome",
          "shortIds": ["abcd1234"]
        }
      }
    }
  ]
}
JSON
safe_restart_xray() { fail "fingerprint state migration must not restart Xray"; }
backup_config() { return 0; }
fix_xray_permissions() { return 0; }

migrate_client_fingerprint_state_2026 "$WORKDIR/.client_fingerprint_marker" \
  || fail "client fingerprint state migration failed"
[[ -f "$WORKDIR/.client_fingerprint_marker" ]] \
  || fail "client fingerprint state marker was not written"
! jq -e 'any(.inbounds[]?; ((.streamSettings.realitySettings? // {}) | has("fingerprint")))' \
  "$CONFIG_FILE" >/dev/null \
  || fail "migration did not remove server-side fingerprint"
[[ "$(jq -r '.routes[0].fingerprint' "$PROFILES_DIR/sample.json")" == "firefox" ]] \
  || fail "migration must not rewrite explicit profile fingerprints"
[[ "$(jq -r '.routes[1].fingerprint' "$PROFILES_DIR/sample.json")" == "edge" ]] \
  || fail "migration must not rewrite explicit route fingerprints"

echo "PASS: client-only fingerprint state reaches subscription URLs"
