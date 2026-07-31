#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORKDIR=$(mktemp -d /tmp/xraytailscale-host-network.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

type migrate_remove_legacy_tcp_tuning_v3 >/dev/null 2>&1 ||
  fail "missing legacy TCP tuning removal migration"
type migrate_legacy_managed_udp443_block_v3 >/dev/null 2>&1 ||
  fail "missing legacy UDP/443 block removal migration"

TEST_ETC="$WORKDIR/etc"
TEST_PROC="$WORKDIR/proc"
XRAY_BACKUPS_DIR="$WORKDIR/backups"
LEGACY_FILE="$TEST_ETC/sysctl.d/99-xraytailscale-tcp.conf"
SYSCTL_CONF="$TEST_ETC/sysctl.conf"
ACTIVE_FILE="$TEST_PROC/tcp_congestion_control"
AVAILABLE_FILE="$TEST_PROC/tcp_available_congestion_control"
MARKER="$WORKDIR/state/.host_tcp_tuning_removed_v3"
SCAN_PATHS="$SYSCTL_CONF:$TEST_ETC/sysctl.d"
EXPECTED_UID=$(id -u)
SYSCTL_CALLS=0

mkdir -p "$TEST_ETC/sysctl.d" "$TEST_PROC" "$XRAY_BACKUPS_DIR"

stat() {
  if [[ "${1:-}" == "-c" && "${2:-}" == "%u" ]]; then
    printf '%s\n' "$EXPECTED_UID"
    return 0
  fi
  command stat "$@"
}

chmod() {
  case "${1:-}" in
    --reference=*) return 0 ;;
    *) command chmod "$@" ;;
  esac
}

chown() { return 0; }

sysctl() {
  [[ "$*" == "-q -w net.ipv4.tcp_congestion_control=cubic" ]] ||
    fail "unexpected sysctl call: $*"
  SYSCTL_CALLS=$((SYSCTL_CALLS + 1))
  printf 'cubic\n' > "$ACTIVE_FILE"
}

cat > "$LEGACY_FILE" <<'EOF'
# XrayTailscale minimal TCP tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

cat > "$SYSCTL_CONF" <<'EOF'
vm.swappiness=10

# BBR TCP Congestion Control Optimization
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3

fs.file-max=100000
EOF

printf 'bbr\n' > "$ACTIVE_FILE"
printf 'reno cubic bbr\n' > "$AVAILABLE_FILE"

migrate_remove_legacy_tcp_tuning_v3 \
  "$MARKER" "$LEGACY_FILE" "$SYSCTL_CONF" "$ACTIVE_FILE" "$AVAILABLE_FILE" \
  "$SCAN_PATHS" "$EXPECTED_UID" >/dev/null ||
  fail "owned legacy TCP tuning migration failed"

[[ ! -e "$LEGACY_FILE" ]] || fail "legacy sysctl.d file was not removed"
[[ -f "$MARKER" ]] || fail "migration marker was not created"
[[ "$(<"$ACTIVE_FILE")" == "cubic" ]] || fail "active congestion control was not changed"
[[ "$SYSCTL_CALLS" -eq 1 ]] || fail "migration did not make exactly one live sysctl change"
grep -q '^vm.swappiness=10$' "$SYSCTL_CONF" || fail "unrelated sysctl prefix was lost"
grep -q '^fs.file-max=100000$' "$SYSCTL_CONF" || fail "unrelated sysctl suffix was lost"
! grep -q 'BBR TCP Congestion Control Optimization' "$SYSCTL_CONF" ||
  fail "legacy marker remained in sysctl.conf"

CONFIG_FILE="$WORKDIR/config.json"
cat > "$CONFIG_FILE" <<'JSON'
{
  "routing": {
    "rules": [
      {"type":"field","network":"udp","port":443,"outboundTag":"block"},
      {"type":"field","network":"udp","port":443,"inboundTag":["custom"],"outboundTag":"block"},
      {"type":"field","network":"tcp,udp","outboundTag":"direct"}
    ]
  }
}
JSON

migrate_legacy_managed_udp443_block_v3 >/dev/null ||
  fail "legacy UDP/443 block migration failed"
! jq -e '.routing.rules[] | select(. == {"type":"field","network":"udp","port":443,"outboundTag":"block"})' "$CONFIG_FILE" >/dev/null ||
  fail "historical bare UDP/443 block was not removed"
jq -e '.routing.rules[] | select(.inboundTag == ["custom"] and .network == "udp" and .port == 443 and .outboundTag == "block")' "$CONFIG_FILE" >/dev/null ||
  fail "operator-scoped UDP/443 rule was removed"

if rg -n 'BBR TCP Congestion Control Optimization|tcp_congestion_control=bbr|sysctl -p|QUIC_RULE|Добавление блокировки QUIC' install.sh update.sh uninstall.sh >/dev/null; then
  fail "fresh install/update/uninstall still manage host TCP tuning or forced UDP/443 block"
fi

echo "PASS: host TCP tuning and legacy UDP/443 block are cleaned up safely"
