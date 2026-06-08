#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "Проверка multi-route XHTTP path generation"

WORKDIR=$(mktemp -d /tmp/xraytailscale-multiroute.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
SNI_LIST="$WORKDIR/sni_list.txt"

mkdir -p "$PROFILES_DIR"
printf '%s\n' 'www.ozon.ru|ru' > "$SNI_LIST"
printf '%s\n' '{"inbounds":[]}' > "$CONFIG_FILE"

printf '%s\n' 30000 > "$WORKDIR/port_cursor"
find_available_random_port() {
  local port_cursor
  port_cursor=$(cat "$WORKDIR/port_cursor")
  port_cursor=$((port_cursor + 1))
  printf '%s\n' "$port_cursor" > "$WORKDIR/port_cursor"
  printf '%s\n' "$port_cursor"
}

backup_config() { return 0; }
safe_restart_xray() { return 0; }
fix_xray_permissions() { return 0; }
close_firewall_port() { return 0; }

ADD_INBOUND_LOG="$WORKDIR/add_inbound.tsv"
add_inbound() {
  local uuid=$1 transport=$2 port=$3 sni=$4 fingerprint=$5 grpc_service_name=${6:-} xhttp_path=${7:-} pq_enabled=${8:-}
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$transport" "$port" "$grpc_service_name" "$xhttp_path" "$pq_enabled" "$uuid" >> "$ADD_INBOUND_LOG"
  return 0
}

set +e
create_profile_all_routes "sample" "no_pause" "hide_subscription" >/dev/null
create_rc=$?
set -e
[[ "$create_rc" -eq 0 ]] || fail "create_profile_all_routes failed with rc=$create_rc"

[[ -s "$ADD_INBOUND_LOG" ]] || fail "add_inbound was not called"

xhttp_count=$(awk -F'\t' '$1 == "xhttp" { count++ } END { print count + 0 }' "$ADD_INBOUND_LOG")
[[ "$xhttp_count" == "2" ]] || fail "expected two XHTTP routes, got $xhttp_count"

awk -F'\t' '
  $1 == "xhttp" {
    if ($4 !~ /^\/xhttp-[a-f0-9]+$/) {
      printf("bad XHTTP path for port %s: %s\n", $2, $4) > "/dev/stderr"
      exit 1
    }
  }
' "$ADD_INBOUND_LOG" || fail "XHTTP routes must pass generated xhttp_path to add_inbound"

echo "✓ Multi-route XHTTP path generation checks passed"
