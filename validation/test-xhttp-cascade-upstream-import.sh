#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORKDIR=$(mktemp -d /tmp/xraytailscale-xhttp-cascade.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
UPSTREAMS_DIR="$WORKDIR/upstreams"
mkdir -p "$PROFILES_DIR" "$UPSTREAMS_DIR"

type _migrate_xhttp_route_path_repair_2026 >/dev/null 2>&1 ||
  fail "missing XHTTP route path repair migration"
type _cascade_parse_vless_uri >/dev/null 2>&1 ||
  fail "missing cascade VLESS URI parser"

jq -n '{
  inbounds: [
    {
      port:41001,
      protocol:"vless",
      settings:{clients:[{id:"11111111-1111-4111-8111-111111111111"}]},
      streamSettings:{
        network:"xhttp",
        security:"reality",
        xhttpSettings:{path:"",host:"www.ozon.ru"},
        realitySettings:{serverNames:["www.ozon.ru"]}
      }
    },
    {
      port:41002,
      protocol:"vless",
      settings:{clients:[{id:"22222222-2222-4222-8222-222222222222"}]},
      streamSettings:{
        network:"xhttp",
        security:"reality",
        xhttpSettings:{path:"/already-live",host:"www.ozon.ru"},
        realitySettings:{serverNames:["www.ozon.ru"]}
      }
    }
  ]
}' > "$CONFIG_FILE"

jq -n '{
  uuid:"11111111-1111-4111-8111-111111111111",
  transport:"xhttp",
  port:41001,
  xhttp_path:"/restore-me",
  routes:[
    {label:"xhttp-legacy",transport:"xhttp",port:41001,xhttp_path:"/restore-me"},
    {label:"xhttp-live",transport:"xhttp",port:41002,xhttp_path:"/profile-stale"}
  ]
}' > "$PROFILES_DIR/sample.json"

_migrate_xhttp_route_path_repair_2026 >/dev/null ||
  fail "XHTTP path repair did not report a change"
[[ "$(jq -r '.inbounds[] | select(.port == 41001) | .streamSettings.xhttpSettings.path' "$CONFIG_FILE")" == "/restore-me" ]] ||
  fail "empty live XHTTP path was not restored from profile metadata"
[[ "$(jq -r '.inbounds[] | select(.port == 41002) | .streamSettings.xhttpSettings.path' "$CONFIG_FILE")" == "/already-live" ]] ||
  fail "non-empty live XHTTP path was overwritten"

TCP_URI='vless://11111111-1111-4111-8111-111111111111@edge.example.com:443?encryption=none&flow=xtls-rprx-vision&type=tcp&security=reality&sni=edge.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN&sid=5dbabfc491c2371d#tcp'
XHTTP_URI='vless://22222222-2222-4222-8222-222222222222@xhttp.example.com:443?encryption=none&type=xhttp&path=%2Fapi%2Fv1&host=xhttp.example.com&mode=auto&security=reality&sni=xhttp.example.com&fp=chrome&pbk=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn&sid=#xhttp'

tcp_json=$(_cascade_parse_vless_uri "$TCP_URI")
jq -e '.transport == "tcp" and .flow == "xtls-rprx-vision" and .short_id == "5dbabfc491c2371d"' <<< "$tcp_json" >/dev/null ||
  fail "TCP cascade URI parsed incorrectly"

xhttp_json=$(_cascade_parse_vless_uri "$XHTTP_URI")
jq -e '.transport == "xhttp" and .xhttp_path == "/api/v1" and .xhttp_mode == "auto"' <<< "$xhttp_json" >/dev/null ||
  fail "XHTTP cascade URI parsed incorrectly"

xhttp_file="$WORKDIR/cascade-xhttp.json"
printf '%s\n' "$xhttp_json" > "$xhttp_file"
xhttp_out=$(_cascade_build_outbound_json "$xhttp_file")
jq -e '.streamSettings.network == "xhttp" and .streamSettings.xhttpSettings.path == "/api/v1" and (.settings.vnext[0].users[0] | has("flow") | not)' <<< "$xhttp_out" >/dev/null ||
  fail "XHTTP cascade outbound generation is incorrect"

if _cascade_parse_vless_uri 'vless://11111111-1111-4111-8111-111111111111@example.com:443?encryption=none&type=grpc&security=reality&sni=example.com&pbk=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN' >/dev/null 2>&1; then
  fail "unsupported cascade gRPC URI was accepted"
fi

grep -q '_cascade_apply_current_upstream "cascade_reconfigure"' "$REPO_ROOT/xraytailscale" ||
  fail "active cascade is not reapplied after reconfiguration"
grep -q -- '-format json -config "$CONFIG_FILE"' "$REPO_ROOT/xraytailscale" ||
  fail "explicit JSON validation format missing"

echo "PASS: XHTTP repair and cascade VLESS import work"
