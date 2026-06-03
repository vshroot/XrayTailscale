#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "x $*" >&2
  exit 1
}

extract_fn() {
  local file="$1"
  local fn="$2"
  awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" { in_fn = 1 }
    in_fn { print }
    in_fn && $0 ~ "^\\}$" { in_fn = 0; exit }
  ' "$file"
}

line_no() {
  local file="$1"
  local needle="$2"
  local line
  line=$(grep -nF "$needle" "$file" | head -1 | cut -d: -f1 || true)
  [[ -n "$line" ]] || fail "missing pattern: $needle"
  printf '%s\n' "$line"
}

assert_order() {
  local file="$1"
  local first="$2"
  local second="$3"
  local first_line second_line
  first_line=$(line_no "$file" "$first")
  second_line=$(line_no "$file" "$second")
  if (( first_line >= second_line )); then
    fail "expected '$first' before '$second'"
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq "$needle" "$file" || fail "missing pattern: $needle"
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  ! grep -Fq "$needle" "$file" || fail "forbidden pattern remains: $needle"
}

tmpdir=$(mktemp -d /tmp/xrayebator-mutation-safety.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

extract_fn xrayebator delete_profile_menu > "$tmpdir/delete_profile_menu"
extract_fn xrayebator change_sni_menu > "$tmpdir/change_sni_menu"
extract_fn xrayebator change_fingerprint_menu > "$tmpdir/change_fingerprint_menu"
extract_fn xrayebator change_port_menu > "$tmpdir/change_port_menu"
extract_fn xrayebator upgrade_profile_to_pq_menu > "$tmpdir/upgrade_profile_to_pq_menu"
extract_fn xrayebator main_menu > "$tmpdir/main_menu"

[[ -s "$tmpdir/delete_profile_menu" ]] || fail "delete_profile_menu not found"
[[ -s "$tmpdir/change_sni_menu" ]] || fail "change_sni_menu not found"
[[ -s "$tmpdir/change_fingerprint_menu" ]] || fail "change_fingerprint_menu not found"
[[ -s "$tmpdir/change_port_menu" ]] || fail "change_port_menu not found"
[[ -s "$tmpdir/upgrade_profile_to_pq_menu" ]] || fail "upgrade_profile_to_pq_menu not found"
[[ -s "$tmpdir/main_menu" ]] || fail "main_menu not found"

echo "Checking operator mutation safety invariants"

assert_contains "$tmpdir/delete_profile_menu" 'backup_config "delete_profile_$profile_name"'
assert_contains "$tmpdir/delete_profile_menu" 'if safe_restart_xray; then'
assert_order "$tmpdir/delete_profile_menu" 'backup_config "delete_profile_$profile_name"' 'if safe_restart_xray; then'
assert_order "$tmpdir/delete_profile_menu" 'if safe_restart_xray; then' 'rm -f "$profile_file"'
assert_order "$tmpdir/delete_profile_menu" 'if safe_restart_xray; then' 'rm -f "$PROFILES_DIR/$profile_name.json"'
assert_order "$tmpdir/delete_profile_menu" 'if safe_restart_xray; then' 'close_firewall_port "$p"'
assert_order "$tmpdir/delete_profile_menu" 'if safe_restart_xray; then' 'close_firewall_port "$port"'
echo "  ok delete_profile_menu"

assert_contains "$tmpdir/change_sni_menu" 'backup_config "change_sni_$selected"'
assert_contains "$tmpdir/change_sni_menu" 'if ! safe_restart_xray; then'
assert_order "$tmpdir/change_sni_menu" 'update_transport_settings_for_sni "$port" "$new_sni" "$CONFIG_FILE"' 'if ! safe_restart_xray; then'
assert_order "$tmpdir/change_sni_menu" 'if ! safe_restart_xray; then' 'update_all_profiles_on_port "$port" "sni" "$new_sni"'
assert_not_contains "$tmpdir/change_sni_menu" '  safe_restart_xray'
echo "  ok change_sni_menu"

assert_contains "$tmpdir/change_fingerprint_menu" 'backup_config "change_fingerprint_$selected"'
assert_contains "$tmpdir/change_fingerprint_menu" 'if ! safe_restart_xray; then'
assert_order "$tmpdir/change_fingerprint_menu" 'select(.port == $port) | .streamSettings.realitySettings.fingerprint' 'if ! safe_restart_xray; then'
assert_order "$tmpdir/change_fingerprint_menu" 'if ! safe_restart_xray; then' 'update_all_profiles_on_port "$port" "fingerprint" "$new_fp"'
assert_not_contains "$tmpdir/change_fingerprint_menu" '  safe_restart_xray'
echo "  ok change_fingerprint_menu"

assert_contains "$tmpdir/change_port_menu" 'backup_config "change_port_$profile_name"'
assert_contains "$tmpdir/change_port_menu" 'if ! safe_restart_xray; then'
assert_order "$tmpdir/change_port_menu" 'backup_config "change_port_$profile_name"' 'if ! safe_restart_xray; then'
assert_order "$tmpdir/change_port_menu" 'if ! safe_restart_xray; then' 'update_all_profiles_port_reference "$old_port" "$new_port"'
assert_order "$tmpdir/change_port_menu" 'if ! safe_restart_xray; then' 'close_firewall_port "$old_port"'
assert_not_contains "$tmpdir/change_port_menu" '  safe_restart_xray'
echo "  ok change_port_menu"

assert_order "$tmpdir/upgrade_profile_to_pq_menu" 'if ! safe_restart_xray; then' "'.transport = \"xhttp\" | .schema_version = 2 | .pq_enabled = true | .xhttp_path = \$path'"
assert_not_contains "$tmpdir/upgrade_profile_to_pq_menu" 'Profile JSON МОЖЕТ'
echo "  ok upgrade_profile_to_pq_menu"

assert_contains "$tmpdir/main_menu" 'Обновить Xray-core'
assert_contains "$tmpdir/main_menu" '10) update_command ;;'
echo "  ok main_menu"

assert_order install.sh 'for ufw_port in 22 80 443 8443 2053 2083 2087 8080 2096 8880 9443; do' 'ufw --force enable'
assert_order install.sh 'if [[ $UFW_ERRORS -gt 0 ]]; then' 'ufw --force enable'
assert_contains install.sh 'if ! ufw reload'
echo "  ok install.sh firewall"

echo "Mutation safety static checks passed"
