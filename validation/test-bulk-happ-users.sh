#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "Проверка bulk HAPP users"

WORKDIR=$(mktemp -d /tmp/xraytailscale-bulk.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
PUBLIC_KEY_FILE="$WORKDIR/.public_key"
VLESS_ENCRYPTION_FILE="$WORKDIR/.vless_encryption"

mkdir -p "$PROFILES_DIR"
printf 'test-public-key\n' > "$PUBLIC_KEY_FILE"
printf 'mlkem768x25519plus.native.test\n' > "$VLESS_ENCRYPTION_FILE"

SAFE_RESTART_COUNT=0
SAFE_RESTART_FAIL=0
backup_config() { return 0; }
fix_xray_permissions() { return 0; }
show_ascii() { return 0; }
sleep() { return 0; }
_bulk_subscription_installed() { return 0; }
_subscription_base_url() { echo "https://vpn.example.com"; }
_subscription_is_local_only() { return 1; }
safe_restart_xray() {
  SAFE_RESTART_COUNT=$((SAFE_RESTART_COUNT + 1))
  [[ "$SAFE_RESTART_FAIL" -eq 0 ]]
}

cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 37174,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "00000000-0000-4000-8000-000000000000", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {"mode": "stream-one", "path": "/xhttp-seed"},
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
          "shortIds": ["abcd1234"]
        }
      },
      "tag": "inbound-37174"
    },
    {
      "listen": "0.0.0.0",
      "port": 39000,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "00000000-0000-4000-8000-000000000000", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
          "shortIds": ["dcba4321"]
        }
      },
      "tag": "inbound-39000"
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {"rules": [{"type": "field", "network": "tcp,udp", "outboundTag": "direct"}]}
}
JSON

cat > "$PROFILES_DIR/_bulk_seed.json" <<'JSON'
{
  "name": "_bulk_seed",
  "uuid": "00000000-0000-4000-8000-000000000000",
  "schema_version": 3,
  "multi_route": true,
  "bulk_seed": true,
  "primary_route": "xhttp-legacy",
  "sub_token": "",
  "created": "2026-07-24 12:00:00",
  "routes": [
    {
      "label": "xhttp-legacy",
      "transport": "xhttp",
      "port": 37174,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "xhttp_path": "/xhttp-seed"
    },
    {
      "label": "tcp-vision",
      "transport": "tcp",
      "port": 39000,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome"
    }
  ],
  "transport": "xhttp",
  "port": 37174,
  "fingerprint": "chrome",
  "sni": "www.ozon.ru",
  "xhttp_path": "/xhttp-seed",
  "pq_enabled": false
}
JSON

type bulk_generate_users_core >/dev/null 2>&1 || fail "missing bulk_generate_users_core"
type bulk_print_users_urls_core >/dev/null 2>&1 || fail "missing bulk_print_users_urls_core"
type bulk_revoke_user_core >/dev/null 2>&1 || fail "missing bulk_revoke_user_core"
type bulk_delete_user_core >/dev/null 2>&1 || fail "missing bulk_delete_user_core"
type bulk_happ_users_menu >/dev/null 2>&1 || fail "missing bulk_happ_users_menu"
type _bulk_seed_profile_file >/dev/null 2>&1 || fail "missing _bulk_seed_profile_file"
type _bulk_seed_ready >/dev/null 2>&1 || fail "missing _bulk_seed_ready"
type _list_visible_profile_names >/dev/null 2>&1 || fail "missing _list_visible_profile_names"

! grep -q '^BULK_DIR=' xraytailscale || fail "BULK_DIR constant should not be required for print-only output"
grep -q '15) bulk_happ_users_menu' xraytailscale || fail "main menu option 15 must route to bulk HAPP users"
grep -q 'Show/print user URLs' xraytailscale || fail "bulk menu must expose print URLs action"
! grep -q 'Export users CSV' xraytailscale || fail "bulk menu must not advertise CSV export"
! _list_visible_profile_names | grep -q '^_bulk_seed$' || fail "bulk seed must be hidden from ordinary profile lists"

generate_output_file="$WORKDIR/generate.out"
bulk_generate_users_core "user" "3" "bulk-test" > "$generate_output_file"
generate_output=$(cat "$generate_output_file")
grep -q '^Batch: bulk-test$' <<< "$generate_output" || fail "bulk generation must print batch id"
grep -Eq '^user-001[[:space:]]+https://vpn\.example\.com/sub/[a-f0-9]{32}[[:space:]]+' <<< "$generate_output" \
  || fail "bulk generation must print user subscription URLs"

[[ "$SAFE_RESTART_COUNT" == "1" ]] || fail "bulk generation must restart Xray once"
for name in user-001 user-002 user-003; do
  [[ -f "$PROFILES_DIR/$name.json" ]] || fail "missing generated profile $name"
  jq -e --arg name "$name" --arg batch "bulk-test" '
    select(.name == $name and .multi_route == true and .bulk_managed == true and .bulk_batch_id == $batch)
    | select((.routes // []) | length == 2)
    | select(.routes[0].port == 37174 and .routes[1].port == 39000)
    | select((.uuid // "") | test("^[0-9a-fA-F-]{36}$"))
    | select((.sub_token // "") | test("^[a-f0-9]{32}$"))
  ' "$PROFILES_DIR/$name.json" >/dev/null || fail "invalid generated profile $name"
done

[[ "$(jq -r '.uuid' "$PROFILES_DIR/user-001.json")" != "$(jq -r '.uuid' "$PROFILES_DIR/user-002.json")" ]] \
  || fail "generated users must have unique UUIDs"
[[ "$(jq -r '.sub_token' "$PROFILES_DIR/user-001.json")" != "$(jq -r '.sub_token' "$PROFILES_DIR/user-002.json")" ]] \
  || fail "generated users must have unique sub_tokens"
[[ "$(_list_visible_profile_names | wc -l | tr -d ' ')" == "3" ]] \
  || fail "visible profile list must include generated users but hide bulk seed"
! _list_visible_profile_names | grep -q '^_bulk_seed$' || fail "bulk seed became visible after generation"

for port in 37174 39000; do
  [[ "$(jq -r --argjson port "$port" '.inbounds[] | select(.port == $port) | .settings.clients | length' "$CONFIG_FILE")" == "4" ]] \
    || fail "port $port must have seed plus three generated clients"
done
jq -e --arg uuid "$(jq -r '.uuid' "$PROFILES_DIR/user-001.json")" '
  .inbounds[] | select(.port == 39000) | .settings.clients[] | select(.id == $uuid and .flow == "xtls-rprx-vision")
' "$CONFIG_FILE" >/dev/null || fail "tcp route must add generated client with Vision flow"
jq -e --arg uuid "$(jq -r '.uuid' "$PROFILES_DIR/user-001.json")" '
  .inbounds[] | select(.port == 37174) | .settings.clients[] | select(.id == $uuid and .flow == "")
' "$CONFIG_FILE" >/dev/null || fail "xhttp route must add generated client without flow"

[[ ! -e "$WORKDIR/bulk/bulk-test.csv" ]] || fail "bulk generation must not write CSV automatically"
print_output_file="$WORKDIR/print.out"
bulk_print_users_urls_core "bulk-test" > "$print_output_file"
print_output=$(cat "$print_output_file")
grep -q '^Batch: bulk-test$' <<< "$print_output" || fail "print URLs must include batch id"
grep -Eq '^user-003[[:space:]]+https://vpn\.example\.com/sub/[a-f0-9]{32}[[:space:]]+' <<< "$print_output" \
  || fail "print URLs must show existing generated users"

old_uuid=$(jq -r '.uuid' "$PROFILES_DIR/user-001.json")
old_token=$(jq -r '.sub_token' "$PROFILES_DIR/user-001.json")
bulk_revoke_user_core "user-001" >/dev/null
[[ "$(jq -r '.uuid' "$PROFILES_DIR/user-001.json")" == "$old_uuid" ]] || fail "revoke must not change UUID"
[[ "$(jq -r '.sub_token' "$PROFILES_DIR/user-001.json")" != "$old_token" ]] || fail "revoke must rotate sub_token"
[[ "$SAFE_RESTART_COUNT" == "1" ]] || fail "revoke must not restart Xray"

delete_uuid=$(jq -r '.uuid' "$PROFILES_DIR/user-002.json")
bulk_delete_user_core "user-002" >/dev/null
[[ "$SAFE_RESTART_COUNT" == "2" ]] || fail "delete must restart Xray once"
[[ ! -f "$PROFILES_DIR/user-002.json" ]] || fail "delete must remove profile after successful restart"
! jq -e --arg uuid "$delete_uuid" '.inbounds[].settings.clients[]? | select(.id == $uuid)' "$CONFIG_FILE" >/dev/null \
  || fail "delete must remove UUID from shared inbounds"

SAFE_RESTART_FAIL=1
fail_uuid=$(jq -r '.uuid' "$PROFILES_DIR/user-003.json")
if bulk_delete_user_core "user-003" >/dev/null 2>&1; then
  fail "delete must fail when safe_restart_xray fails"
fi
[[ -f "$PROFILES_DIR/user-003.json" ]] || fail "failed delete must keep profile JSON"
SAFE_RESTART_FAIL=0
[[ -n "$fail_uuid" ]] || fail "failed delete fixture invalid"

echo "✓ Bulk HAPP users checks passed"
