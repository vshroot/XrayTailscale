#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "Проверка cascade routing invariants"

WORKDIR=$(mktemp -d /tmp/xraytailscale-cascade.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

CONFIG_FILE="$WORKDIR/config.json"
UPSTREAMS_DIR="$WORKDIR/upstreams"
CASCADE_ACTIVE_FILE="$WORKDIR/.cascade_active"

backup_config() { return 0; }
safe_restart_xray() { return 0; }
fix_xray_permissions() { return 0; }
show_ascii() { return 0; }
sleep() { return 0; }

mkdir -p "$UPSTREAMS_DIR"

cat > "$CONFIG_FILE" <<'JSON'
{
  "routing": {
    "rules": [
      {"type":"field","domain":["domain:example.ru"],"outboundTag":"direct"},
      {"type":"field","network":"udp","port":443,"outboundTag":"block"},
      {"type":"field","network":"tcp,udp","outboundTag":"direct"},
      {"type":"field","network":"tcp,udp","outboundTag":"direct"}
    ]
  },
  "outbounds": [
    {"protocol":"freedom","settings":{"domainStrategy":"UseIPv4","fragment":{"packets":"tlshello"}},"tag":"direct"},
    {"protocol":"blackhole","tag":"block"}
  ]
}
JSON

cat > "$UPSTREAMS_DIR/cascade.json" <<'JSON'
{
  "version": 1,
  "tag": "cascade-upstream",
  "address": "203.0.113.10",
  "port": 443,
  "uuid": "11111111-1111-4111-8111-111111111111",
  "transport": "tcp",
  "sni": "front.example.com",
  "fingerprint": "chrome",
  "public_key": "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN",
  "short_id": "abcd1234",
  "flow": "xtls-rprx-vision"
}
JSON

type _cascade_build_outbound_json >/dev/null 2>&1 || fail "missing _cascade_build_outbound_json"
type _cascade_build_fragment_outbound_json >/dev/null 2>&1 || fail "missing _cascade_build_fragment_outbound_json"
type _cascade_validate_upstream_fields >/dev/null 2>&1 || fail "missing _cascade_validate_upstream_fields"
type configure_cascade_upstream >/dev/null 2>&1 || fail "missing configure_cascade_upstream"
type enable_cascade_mode >/dev/null 2>&1 || fail "missing enable_cascade_mode"
type disable_cascade_mode >/dev/null 2>&1 || fail "missing disable_cascade_mode"
type cascade_mode_menu >/dev/null 2>&1 || fail "missing cascade_mode_menu"
type setup_outbound_server_menu >/dev/null 2>&1 || fail "missing setup_outbound_server_menu"

grep -q '^UPSTREAMS_DIR=' xraytailscale || fail "missing UPSTREAMS_DIR constant"
grep -q '^CASCADE_ACTIVE_FILE=' xraytailscale || fail "missing CASCADE_ACTIVE_FILE constant"
grep -q '13) cascade_mode_menu' xraytailscale || fail "main menu option 13 must route to cascade menu"
grep -q '14) setup_outbound_server_menu' xraytailscale || fail "main menu option 14 must route to outbound server setup"

_cascade_validate_upstream_fields "203.0.113.10" "443" "11111111-1111-4111-8111-111111111111" \
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN" "abcd1234" "front.example.com" "chrome" "" \
  || fail "valid upstream fields were rejected"
if _cascade_validate_upstream_fields "10.0.0.1" "443" "11111111-1111-4111-8111-111111111111" \
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN" "abcd1234" "front.example.com" "chrome" "" >/dev/null 2>&1; then
  fail "private upstream address must be rejected"
fi

outbound_json=$(_cascade_build_outbound_json "$UPSTREAMS_DIR/cascade.json")
fragment_json=$(_cascade_build_fragment_outbound_json)

jq -e 'select(.tag == "cascade-upstream" and .protocol == "vless")' <<< "$outbound_json" >/dev/null \
  || fail "cascade outbound JSON invalid"
jq -e '.streamSettings.sockopt | select(.dialerProxy == "cascade-fragment" and .tcpFastOpen == true and .tcpNoDelay == true)' <<< "$outbound_json" >/dev/null \
  || fail "cascade outbound must use cascade-fragment dialerProxy"
jq -e 'select(.tag == "cascade-fragment" and .protocol == "freedom" and .settings.fragment.packets == "tlshello")' <<< "$fragment_json" >/dev/null \
  || fail "cascade fragment outbound JSON invalid"
! jq -e '.settings.vnext[0].users[0].packetEncoding' <<< "$outbound_json" >/dev/null \
  || fail "plain TCP cascade must omit packetEncoding"

enable_cascade_mode < <(printf 'y\n\n')

jq -e '.outbounds[] | select(.tag == "cascade-upstream" and .protocol == "vless")' "$CONFIG_FILE" >/dev/null \
  || fail "cascade outbound missing after enable"
jq -e '.outbounds[] | select(.tag == "cascade-fragment" and .protocol == "freedom")' "$CONFIG_FILE" >/dev/null \
  || fail "cascade fragment missing after enable"
jq -e '.routing.rules[0] | select(.outboundTag == "direct" and .ip[0] == "203.0.113.10")' "$CONFIG_FILE" >/dev/null \
  || fail "upstream direct IP exception missing"
jq -e '.routing.rules[1] | select(.network == "udp" and (.port|tostring) == "443" and .outboundTag == "block")' "$CONFIG_FILE" >/dev/null \
  || fail "udp/443 block rule missing before cascade catch-all"
jq -e '.routing.rules[] | select(.domain[0] == "domain:example.ru" and .outboundTag == "direct")' "$CONFIG_FILE" >/dev/null \
  || fail "existing bypass direct rule was not preserved"
jq -e '.routing.rules[] | select(.network == "tcp,udp" and .outboundTag == "cascade-upstream")' "$CONFIG_FILE" >/dev/null \
  || fail "catch-all was not switched to cascade"
[[ "$(jq '[.routing.rules[] | select(.network == "tcp,udp" and (.domain // null) == null and (.ip // null) == null and (.port // null) == null)] | length' "$CONFIG_FILE")" == "1" ]] \
  || fail "catch-all rules were not normalized"
[[ -f "$CASCADE_ACTIVE_FILE" ]] || fail "cascade active marker missing after enable"

disable_cascade_mode < <(printf 'y\n\n')

! jq -e '.outbounds[]? | select(.tag == "cascade-upstream")' "$CONFIG_FILE" >/dev/null \
  || fail "cascade outbound still present after disable"
! jq -e '.outbounds[]? | select(.tag == "cascade-fragment")' "$CONFIG_FILE" >/dev/null \
  || fail "cascade fragment still present after disable"
! jq -e '.routing.rules[]? | select(.outboundTag == "direct" and .ip[0] == "203.0.113.10")' "$CONFIG_FILE" >/dev/null \
  || fail "cascade upstream direct exception still present after disable"
jq -e '.routing.rules[] | select(.network == "tcp,udp" and .outboundTag == "direct")' "$CONFIG_FILE" >/dev/null \
  || fail "catch-all was not restored to direct"
jq -e '.routing.rules[] | select(.network == "udp" and (.port|tostring) == "443" and .outboundTag == "block")' "$CONFIG_FILE" >/dev/null \
  || fail "baseline udp/443 block rule must be preserved after disable"
[[ ! -f "$CASCADE_ACTIVE_FILE" ]] || fail "cascade active marker still present after disable"

echo "✓ Cascade routing checks passed"
