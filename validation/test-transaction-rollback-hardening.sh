#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORKDIR=$(mktemp -d /tmp/xraytailscale-transaction.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
XRAY_BACKUPS_DIR="$WORKDIR/backups"
XRAY_BIN="$WORKDIR/xray"
mkdir -p "$PROFILES_DIR" "$XRAY_BACKUPS_DIR"

type _restore_config_backup >/dev/null 2>&1 || fail "missing exact config rollback helper"
type _snapshot_profiles >/dev/null 2>&1 || fail "missing profile snapshot helper"
type _restore_profiles_snapshot >/dev/null 2>&1 || fail "missing profile snapshot restore helper"

printf '#!/bin/sh\nprintf "%s\\n" "invalid test config"\nexit 1\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"

printf '{"value":"expected"}\n' > "$CONFIG_FILE"
rollback_config=""
backup_config "expected_operation" rollback_config >/dev/null ||
  fail "backup_config failed"
[[ -n "$rollback_config" && -f "$rollback_config" ]] ||
  fail "backup_config did not return the exact backup path"

printf '{"value":"broken"}\n' > "$CONFIG_FILE"
printf '{"value":"wrong-newer-operation"}\n' > "$XRAY_BACKUPS_DIR/config_99999999_wrong.json"
restart_rc=0
safe_restart_xray "$rollback_config" >/dev/null 2>&1 || restart_rc=$?
[[ "$restart_rc" -eq 1 ]] || fail "invalid config unexpectedly passed validation"
[[ "$(jq -r '.value' "$CONFIG_FILE")" == "expected" ]] ||
  fail "safe_restart_xray restored an unrelated backup"

printf '#!/bin/sh\nprintf "%s\\n" "Configuration OK."\nexit 0\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
ensure_xray_service_unit() { return 0; }
sleep() { :; }
systemctl() {
  if [[ "${1:-}" == "is-active" ]]; then
    return 1
  fi
  return 0
}

printf '{"value":"service-expected"}\n' > "$CONFIG_FILE"
service_rollback=""
backup_config "service_expected" service_rollback >/dev/null ||
  fail "service rollback backup failed"
printf '{"value":"service-new"}\n' > "$CONFIG_FILE"
service_rc=0
safe_restart_xray "$service_rollback" >/dev/null 2>&1 || service_rc=$?
[[ "$service_rc" -eq 1 ]] || fail "failed service restart unexpectedly succeeded"
[[ "$(jq -r '.value' "$CONFIG_FILE")" == "service-expected" ]] ||
  fail "service restart failure did not restore its exact backup"

printf '{"name":"sample","port":43001}\n' > "$PROFILES_DIR/sample.json"
profiles_snapshot=""
_snapshot_profiles profiles_snapshot || fail "profile snapshot failed"
printf '{"name":"sample","port":43002}\n' > "$PROFILES_DIR/sample.json"
_restore_profiles_snapshot "$profiles_snapshot" >/dev/null ||
  fail "profile snapshot restore failed"
_discard_profiles_snapshot "$profiles_snapshot"
[[ "$(jq -r '.port' "$PROFILES_DIR/sample.json")" == "43001" ]] ||
  fail "profile snapshot did not restore original JSON"

echo "PASS: exact rollback helpers restore the intended config/profile state"
