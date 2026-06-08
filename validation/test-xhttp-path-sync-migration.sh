#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "Проверка XHTTP path sync migration"

WORKDIR=$(mktemp -d /tmp/xraytailscale-xhttp-path.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"

mkdir -p "$PROFILES_DIR"

cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 37174,
      "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555"}], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {"mode": "stream-one", "path": ""},
        "realitySettings": {"shortIds": ["738e042b"]}
      }
    },
    {
      "port": 36058,
      "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555"}], "decryption": "mlkem768x25519plus.native.test"},
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {"mode": "stream-one", "path": ""},
        "realitySettings": {"shortIds": ["beef5678"]}
      }
    }
  ]
}
JSON

cat > "$PROFILES_DIR/happ.json" <<'JSON'
{
  "name": "happ",
  "uuid": "11111111-2222-3333-4444-555555555555",
  "multi_route": true,
  "routes": [
    {
      "label": "xhttp-legacy",
      "transport": "xhttp",
      "port": 37174,
      "xhttp_path": "/xhttp-4ecb1f64"
    },
    {
      "label": "xhttp-pq",
      "transport": "xhttp",
      "port": 36058,
      "xhttp_path": "/xhttp-90cafe12"
    }
  ]
}
JSON

if ! _migrate_xhttp_path_sync_2026; then
  fail "XHTTP path sync migration should report changed config"
fi

jq -e '.inbounds[] | select(.port == 37174) | .streamSettings.xhttpSettings.path == "/xhttp-4ecb1f64"' "$CONFIG_FILE" >/dev/null \
  || fail "legacy XHTTP inbound path was not restored from profile route"
jq -e '.inbounds[] | select(.port == 36058) | .streamSettings.xhttpSettings.path == "/xhttp-90cafe12"' "$CONFIG_FILE" >/dev/null \
  || fail "PQ XHTTP inbound path was not restored from profile route"

echo "✓ XHTTP path sync migration checks passed"
