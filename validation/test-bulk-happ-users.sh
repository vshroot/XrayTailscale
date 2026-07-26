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
CREATE_SEED_COUNT=0
create_profile_all_routes() {
  local name="$1" pause_after="${2:-}" subscription_output="${3:-}"
  [[ "$name" == "_bulk_seed" && "$pause_after" == "no_pause" && "$subscription_output" == "hide_subscription" ]] \
    || return 1
  CREATE_SEED_COUNT=$((CREATE_SEED_COUNT + 1))
  cat > "$PROFILES_DIR/_bulk_seed.json" <<'JSON'
{
  "name": "_bulk_seed",
  "uuid": "11111111-1111-4111-8111-111111111111",
  "schema_version": 3,
  "multi_route": true,
  "bulk_seed": true,
  "primary_route": "xhttp-legacy",
  "sub_token": "",
  "created": "2026-07-24 12:30:00",
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
type _bulk_list_batches >/dev/null 2>&1 || fail "missing _bulk_list_batches"
type _bulk_select_batch_for_print >/dev/null 2>&1 || fail "missing _bulk_select_batch_for_print"
type bulk_repair_stale_users_core >/dev/null 2>&1 || fail "missing bulk_repair_stale_users_core"
type repair_stale_subscription_profiles_core >/dev/null 2>&1 || fail "missing repair_stale_subscription_profiles_core"
type _list_visible_profile_names >/dev/null 2>&1 || fail "missing _list_visible_profile_names"

! grep -q '^BULK_DIR=' xraytailscale || fail "BULK_DIR constant should not be required for print-only output"
grep -q '10) bulk_happ_users_menu' xraytailscale || fail "main menu option 10 must route to bulk HAPP users"
grep -q 'bulk-repair|subscription-repair)' xraytailscale || fail "CLI must expose bulk-repair and subscription-repair subcommands"
grep -q 'Show/print user URLs' xraytailscale || fail "bulk menu must expose print URLs action"
grep -q '_bulk_select_batch_for_print' xraytailscale || fail "bulk menu must use numbered batch selection"
! grep -q 'Batch ID для вывода URL' xraytailscale || fail "bulk menu must not require typing batch id manually"
! grep -q 'Export users CSV' xraytailscale || fail "bulk menu must not advertise CSV export"
! _list_visible_profile_names | grep -q '^_bulk_seed$' || fail "bulk seed must be hidden from ordinary profile lists"

cat > "$PROFILES_DIR/_bulk_seed.json" <<'JSON'
{
  "name": "_bulk_seed",
  "uuid": "22222222-2222-4222-8222-222222222222",
  "schema_version": 3,
  "multi_route": true,
  "bulk_seed": true,
  "primary_route": "xhttp-legacy",
  "sub_token": "",
  "created": "2026-07-24 12:10:00",
  "routes": [
    {
      "label": "stale-xhttp",
      "transport": "xhttp",
      "port": 59999,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "xhttp_path": "/xhttp-stale"
    }
  ],
  "transport": "xhttp",
  "port": 59999,
  "fingerprint": "chrome",
  "sni": "www.ozon.ru",
  "xhttp_path": "/xhttp-stale",
  "pq_enabled": false
}
JSON
CREATE_SEED_COUNT=0
stale_seed_output_file="$WORKDIR/stale-seed.out"
if ! _bulk_seed_ready > "$stale_seed_output_file" 2>&1; then
  cat "$stale_seed_output_file" >&2
  fail "bulk seed with missing live ports must be recreated"
fi
[[ "$CREATE_SEED_COUNT" == "1" ]] || fail "stale bulk seed must trigger one seed recreation"
jq -e --slurpfile cfg "$CONFIG_FILE" '
  .bulk_seed == true
  and .bulk_managed == false
  and .sub_token == ""
  and all((.routes // [])[]; .port as $p | any($cfg[0].inbounds[]?; .port == $p))
' "$PROFILES_DIR/_bulk_seed.json" >/dev/null || fail "recreated bulk seed must point only to live inbounds"

cat > "$PROFILES_DIR/legacy-001.json" <<'JSON'
{
  "name": "legacy-001",
  "uuid": "33333333-3333-4333-8333-333333333333",
  "schema_version": 3,
  "multi_route": true,
  "bulk_managed": true,
  "bulk_batch_id": "legacy-batch",
  "primary_route": "stale-xhttp",
  "sub_token": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "created": "2026-07-24 12:20:00",
  "routes": [
    {
      "label": "stale-xhttp",
      "transport": "xhttp",
      "port": 59999,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "xhttp_path": "/xhttp-stale"
    }
  ],
  "transport": "xhttp",
  "port": 59999,
  "fingerprint": "chrome",
  "sni": "www.ozon.ru",
  "xhttp_path": "/xhttp-stale",
  "pq_enabled": false
}
JSON

cat > "$PROFILES_DIR/regular-001.json" <<'JSON'
{
  "name": "regular-001",
  "uuid": "44444444-4444-4444-8444-444444444444",
  "schema_version": 3,
  "multi_route": true,
  "primary_route": "stale-xhttp",
  "sub_token": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "created": "2026-07-24 12:25:00",
  "routes": [
    {
      "label": "stale-xhttp",
      "transport": "xhttp",
      "port": 58888,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "xhttp_path": "/xhttp-stale-regular"
    }
  ],
  "transport": "xhttp",
  "port": 58888,
  "fingerprint": "chrome",
  "sni": "www.ozon.ru",
  "xhttp_path": "/xhttp-stale-regular",
  "pq_enabled": false
}
JSON

repair_stale_subscription_profiles_core >/dev/null
[[ "$SAFE_RESTART_COUNT" == "1" ]] || fail "stale subscription profile repair must restart Xray once"
jq -e --slurpfile cfg "$CONFIG_FILE" '
  .name == "legacy-001"
  and .uuid == "33333333-3333-4333-8333-333333333333"
  and .sub_token == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  and .bulk_batch_id == "legacy-batch"
  and (.routes | length == 2)
  and all((.routes // [])[]; .port as $p | any($cfg[0].inbounds[]?; .port == $p))
  and .port == .routes[0].port
' "$PROFILES_DIR/legacy-001.json" >/dev/null || fail "stale bulk user must be synced to live seed routes without changing credentials"
jq -e --slurpfile cfg "$CONFIG_FILE" '
  .name == "regular-001"
  and .uuid == "44444444-4444-4444-8444-444444444444"
  and .sub_token == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  and (.bulk_managed // false) == false
  and (.routes | length == 2)
  and all((.routes // [])[]; .port as $p | any($cfg[0].inbounds[]?; .port == $p))
  and .port == .routes[0].port
' "$PROFILES_DIR/regular-001.json" >/dev/null || fail "ordinary stale subscription profile must be synced to live seed routes without changing credentials"
for port in 37174 39000; do
  jq -e --argjson port "$port" '
    .inbounds[] | select(.port == $port) | .settings.clients[] | select(.id == "33333333-3333-4333-8333-333333333333")
  ' "$CONFIG_FILE" >/dev/null || fail "repaired bulk user UUID must be added to live inbound $port"
  jq -e --argjson port "$port" '
    .inbounds[] | select(.port == $port) | .settings.clients[] | select(.id == "44444444-4444-4444-8444-444444444444")
  ' "$CONFIG_FILE" >/dev/null || fail "repaired ordinary profile UUID must be added to live inbound $port"
done
legacy_urls=$(XRAYTAILSCALE_SERVER_ADDR_OVERRIDE="vpn.example.com" _generate_vless_urls_for_profile "$PROFILES_DIR/legacy-001.json") \
  || fail "repaired bulk user subscription must generate live VLESS URLs"
grep -q '^vless://' <<< "$legacy_urls" || fail "repaired bulk user subscription must generate live VLESS URLs"
regular_urls=$(XRAYTAILSCALE_SERVER_ADDR_OVERRIDE="vpn.example.com" _generate_vless_urls_for_profile "$PROFILES_DIR/regular-001.json") \
  || fail "repaired ordinary subscription must generate live VLESS URLs"
grep -q '^vless://' <<< "$regular_urls" || fail "repaired ordinary subscription must generate live VLESS URLs"

cat > "$PROFILES_DIR/bulk-missing-client.json" <<'JSON'
{
  "name": "bulk-missing-client",
  "uuid": "55555555-5555-4555-8555-555555555555",
  "schema_version": 3,
  "multi_route": true,
  "bulk_managed": true,
  "bulk_batch_id": "missing-client-batch",
  "primary_route": "xhttp-legacy",
  "sub_token": "cccccccccccccccccccccccccccccccc",
  "created": "2026-07-24 12:35:00",
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

SAFE_RESTART_COUNT=0
bulk_repair_stale_users_core >/dev/null
[[ "$SAFE_RESTART_COUNT" == "1" ]] \
  || fail "bulk repair must restart Xray when a live-port bulk profile is missing inbound clients"
for port in 37174 39000; do
  jq -e --argjson port "$port" '
    .inbounds[] | select(.port == $port) | .settings.clients[] | select(.id == "55555555-5555-4555-8555-555555555555")
  ' "$CONFIG_FILE" >/dev/null || fail "live-port bulk repair must add missing UUID to inbound $port"
done
missing_bulk_urls=$(XRAYTAILSCALE_SERVER_ADDR_OVERRIDE="vpn.example.com" _generate_vless_urls_for_profile "$PROFILES_DIR/bulk-missing-client.json") \
  || fail "live-port repaired bulk user subscription must generate live VLESS URLs"
grep -q '^vless://' <<< "$missing_bulk_urls" || fail "live-port repaired bulk user subscription must generate live VLESS URLs"

cat > "$PROFILES_DIR/regular-missing-client.json" <<'JSON'
{
  "name": "regular-missing-client",
  "uuid": "66666666-6666-4666-8666-666666666666",
  "schema_version": 3,
  "multi_route": true,
  "primary_route": "xhttp-legacy",
  "sub_token": "dddddddddddddddddddddddddddddddd",
  "created": "2026-07-24 12:40:00",
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

SAFE_RESTART_COUNT=0
repair_stale_subscription_profiles_core >/dev/null
[[ "$SAFE_RESTART_COUNT" == "1" ]] \
  || fail "ordinary repair must restart Xray when a live-port subscribed profile is missing inbound clients"
for port in 37174 39000; do
  jq -e --argjson port "$port" '
    .inbounds[] | select(.port == $port) | .settings.clients[] | select(.id == "66666666-6666-4666-8666-666666666666")
  ' "$CONFIG_FILE" >/dev/null || fail "live-port ordinary repair must add missing UUID to inbound $port"
done
missing_regular_urls=$(XRAYTAILSCALE_SERVER_ADDR_OVERRIDE="vpn.example.com" _generate_vless_urls_for_profile "$PROFILES_DIR/regular-missing-client.json") \
  || fail "live-port repaired ordinary subscription must generate live VLESS URLs"
grep -q '^vless://' <<< "$missing_regular_urls" || fail "live-port repaired ordinary subscription must generate live VLESS URLs"

jq '
  .inbounds += [
    {
      "listen": "0.0.0.0",
      "port": 41000,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "77777777-7777-4777-8777-777777777777", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {"mode": "stream-one", "path": ""},
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
          "fingerprint": "chrome",
          "shortIds": ["ea7e0001"]
        }
      },
      "tag": "inbound-41000"
    },
    {
      "listen": "0.0.0.0",
      "port": 41001,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "77777777-7777-4777-8777-777777777777", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverNames": ["www.ozon.ru"],
          "fingerprint": "chrome",
          "shortIds": ["ea7e0002"]
        }
      },
      "tag": "inbound-41001"
    }
  ]
' "$CONFIG_FILE" > "$WORKDIR/config-empty-live-path.json" \
  || fail "failed to add empty-live-path inbounds fixture"
mv "$WORKDIR/config-empty-live-path.json" "$CONFIG_FILE"

cat > "$PROFILES_DIR/regular-empty-live-path.json" <<'JSON'
{
  "name": "regular-empty-live-path",
  "uuid": "77777777-7777-4777-8777-777777777777",
  "schema_version": 3,
  "multi_route": true,
  "primary_route": "xhttp-legacy",
  "sub_token": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  "created": "2026-07-24 12:45:00",
  "routes": [
    {
      "label": "xhttp-legacy",
      "transport": "xhttp",
      "port": 41000,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "xhttp_path": "/xhttp-profile-only"
    },
    {
      "label": "tcp-vision",
      "transport": "tcp",
      "port": 41001,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome"
    }
  ],
  "transport": "xhttp",
  "port": 41000,
  "fingerprint": "chrome",
  "sni": "www.ozon.ru",
  "xhttp_path": "/xhttp-profile-only",
  "pq_enabled": false
}
JSON

SAFE_RESTART_COUNT=0
repair_stale_subscription_profiles_core >/dev/null
[[ "$SAFE_RESTART_COUNT" == "1" ]] \
  || fail "ordinary repair must restart Xray when subscribed XHTTP profile has empty live inbound path"
jq -e '
  .name == "regular-empty-live-path"
  and .uuid == "77777777-7777-4777-8777-777777777777"
  and .sub_token == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  and (.routes | length == 2)
  and .routes[0].port == 37174
  and .routes[0].xhttp_path == "/xhttp-seed"
' "$PROFILES_DIR/regular-empty-live-path.json" >/dev/null \
  || fail "ordinary repair must resync empty-live-path profile to seed routes without changing credentials"
for port in 37174 39000; do
  jq -e --argjson port "$port" '
    .inbounds[] | select(.port == $port) | .settings.clients[] | select(.id == "77777777-7777-4777-8777-777777777777")
  ' "$CONFIG_FILE" >/dev/null || fail "empty-live-path ordinary repair must add UUID to seed inbound $port"
done
empty_path_regular_urls=$(XRAYTAILSCALE_SERVER_ADDR_OVERRIDE="vpn.example.com" _generate_vless_urls_for_profile "$PROFILES_DIR/regular-empty-live-path.json") \
  || fail "empty-live-path repaired ordinary subscription must generate live VLESS URLs"
grep -q 'type=xhttp&path=%2Fxhttp-seed&mode=stream-one#regular-empty-live-path-xhttp-legacy' <<< "$empty_path_regular_urls" \
  || fail "empty-live-path repaired ordinary subscription must use seed XHTTP path"
SAFE_RESTART_COUNT=0

generate_output_file="$WORKDIR/generate.out"
bulk_generate_users_core "user" "3" "bulk-test" > "$generate_output_file"
generate_output=$(cat "$generate_output_file")
grep -q '^Batch: bulk-test$' <<< "$generate_output" || fail "bulk generation must print batch id"
grep -Eq '^user-001[[:space:]]+https://vpn\.example\.com/sub/[a-f0-9]{32}$' <<< "$generate_output" \
  || fail "bulk generation must print user subscription URLs"
! grep -Eq '^user-001[[:space:]]+https://vpn\.example\.com/sub/[a-f0-9]{32}[[:space:]]+[0-9a-fA-F-]{36}$' <<< "$generate_output" \
  || fail "bulk generation output must not include UUID"

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
[[ "$(_list_visible_profile_names | wc -l | tr -d ' ')" == "8" ]] \
  || fail "visible profile list must include repaired and generated users but hide bulk seed"
! _list_visible_profile_names | grep -q '^_bulk_seed$' || fail "bulk seed became visible after generation"
bulk_batches=$(_bulk_list_batches)
grep -q '^bulk-test$' <<< "$bulk_batches" || fail "bulk batches list must include generated batch"
grep -q '^legacy-batch$' <<< "$bulk_batches" || fail "bulk batches list must include repaired legacy batch"
grep -q '^missing-client-batch$' <<< "$bulk_batches" || fail "bulk batches list must include live-port repaired batch"
SELECTED_BULK_BATCH="not-set"
_bulk_select_batch_for_print < <(printf '2\n') >/dev/null
[[ "$SELECTED_BULK_BATCH" == "bulk-test" ]] || fail "batch selection by number must set selected batch"

for port in 37174 39000; do
  [[ "$(jq -r --argjson port "$port" '.inbounds[] | select(.port == $port) | .settings.clients | length' "$CONFIG_FILE")" == "9" ]] \
    || fail "port $port must have seed plus five repaired profiles plus three generated clients"
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
grep -Eq '^name[[:space:]]+subscription_url$' <<< "$print_output" || fail "print URLs header must not include UUID"
grep -Eq '^user-003[[:space:]]+https://vpn\.example\.com/sub/[a-f0-9]{32}$' <<< "$print_output" \
  || fail "print URLs must show existing generated users"
! grep -Eq '^user-003[[:space:]]+https://vpn\.example\.com/sub/[a-f0-9]{32}[[:space:]]+[0-9a-fA-F-]{36}$' <<< "$print_output" \
  || fail "print URLs must not include UUID"

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
