#!/bin/bash
# test-pq-migration-static.sh — DRY-хелпер и автоматическая PQ-миграция.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
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
  [[ -n "$line" ]] || fail "не найден шаблон: $needle"
  printf '%s\n' "$line"
}

assert_order() {
  local file="$1"
  local first="$2"
  local second="$3"
  local first_line second_line
  first_line=$(line_no "$file" "$first")
  second_line=$(line_no "$file" "$second")
  (( first_line < second_line )) || fail "ожидался порядок: '$first' до '$second'"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq "$needle" "$file" || fail "не найден шаблон: $needle"
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  ! grep -Fq "$needle" "$file" || fail "запрещённый шаблон остался: $needle"
}

WORKDIR=$(mktemp -d /tmp/xraytailscale-pq-migration.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Проверка PQ auto-migration и DRY-хелпера"

extract_fn src/75-pq-adguard.sh _pq_upgrade_one_profile > "$WORKDIR/pq_helper"
extract_fn src/75-pq-adguard.sh upgrade_profile_to_pq_menu > "$WORKDIR/pq_menu"
extract_fn src/20-migrations.sh _migrate_pq_all_profiles_2026 > "$WORKDIR/pq_migration"
extract_fn src/20-migrations.sh _list_legacy_pq_profile_names > "$WORKDIR/pq_legacy_list"
extract_fn src/55-main-menu.sh main_menu > "$WORKDIR/main_menu"

[[ -s "$WORKDIR/pq_helper" ]] || fail "_pq_upgrade_one_profile не определён"
[[ -s "$WORKDIR/pq_migration" ]] || fail "_migrate_pq_all_profiles_2026 не определена"
assert_contains "$WORKDIR/main_menu" 'run_migration "pq_all_2026" "PQ: legacy-профили → XHTTP+PQ" _migrate_pq_all_profiles_2026 || ((migration_failures++))'
echo "  ✓ helper, миграция и регистрация pq_all_2026"

# config.json сначала успешно применяется, только затем профили получают PQ-флаг.
assert_order "$WORKDIR/pq_helper" 'if ! safe_restart_xray "$rollback_config"; then' "'.transport = \"xhttp\" | .schema_version = 2 | .pq_enabled = true | .xhttp_path = \$path'"
assert_contains "$WORKDIR/pq_helper" 'backup_config "upgrade_profile_pq_$name" rollback_config'
assert_not_contains "$WORKDIR/pq_helper" 'generate_connection'
assert_not_contains "$WORKDIR/pq_helper" 'read '
assert_not_contains "$WORKDIR/pq_helper" 'sleep '
echo "  ✓ порядок config → profile; helper без UI"

# Меню владеет только Phase 1a и выводом ссылки, мутации живут в helper.
assert_contains "$WORKDIR/pq_menu" '_pq_upgrade_one_profile "$selected"'
assert_contains "$WORKDIR/pq_menu" 'generate_connection "$selected"'
assert_not_contains "$WORKDIR/pq_menu" 'safe_jq_write'
assert_not_contains "$WORKDIR/pq_menu" '.pq_enabled = true'
assert_not_contains "$WORKDIR/pq_menu" 'safe_restart_xray'
echo "  ✓ DRY: меню вызывает helper и не дублирует мутации"

assert_contains "$WORKDIR/pq_legacy_list" '_profile_is_bulk_seed_file "$profile_file"'
assert_contains "$WORKDIR/pq_legacy_list" 'profile_has_routes "$profile_file"'
assert_contains "$WORKDIR/pq_legacy_list" '.pq_enabled // false'
assert_contains "$WORKDIR/pq_migration" '_pq_upgrade_one_profile "$profile_name"'
assert_contains "$WORKDIR/pq_migration" 'return 2'
assert_not_contains "$WORKDIR/pq_migration" 'backup_config '
assert_not_contains "$WORKDIR/pq_migration" 'safe_restart_xray "'
assert_contains "$WORKDIR/main_menu" '.pq_migration_warned'
assert_contains "$WORKDIR/main_menu" 'read -r pq_migration_answer || {'
assert_contains "$WORKDIR/main_menu" 'Внимание: старые single-route профили будут переведены на XHTTP+PQ. Ручные vless://-ссылки перестанут работать (подписки обновятся сами).'
echo "  ✓ фильтры legacy-профилей и одноразовое предупреждение"

# Поведенческая проверка no-op: пустой PROFILES_DIR не вызывает ни запись,
# ни бэкап/рестарт и возвращает ровно 1, оставляя config.json нетронутым.
# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"
CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
mkdir -p "$PROFILES_DIR"
cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"}
    }
  ]
}
JSON
config_before=$(cksum < "$CONFIG_FILE")
VLESS_DECRYPTION_FILE="$WORKDIR/missing.vless_decryption"
VLESS_ENCRYPTION_FILE="$WORKDIR/missing.vless_encryption"

noop_rc=0
noop_output=$(
  safe_jq_write() { echo "unexpected safe_jq_write" >&2; return 99; }
  backup_config() { echo "unexpected backup_config" >&2; return 99; }
  safe_restart_xray() { echo "unexpected safe_restart_xray" >&2; return 99; }
  _pq_upgrade_one_profile() { echo "unexpected _pq_upgrade_one_profile" >&2; return 99; }
  _migrate_pq_all_profiles_2026
) || noop_rc=$?
[[ "$noop_rc" -eq 1 ]] || fail "пустой PROFILES_DIR: ожидался no-op rc=1, получен $noop_rc; вывод: $noop_output"
[[ "$(cksum < "$CONFIG_FILE")" == "$config_before" ]] || fail "no-op изменил config.json"
[[ -z "$(find "$PROFILES_DIR" -mindepth 1 -print -quit)" ]] || fail "no-op создал файлы в пустом PROFILES_DIR"
echo "  ✓ поведение: пустой PROFILES_DIR → rc=1, config.json не изменён"

# Поведенческая проверка фильтра: multi-route, PQ и bulk-seed не мигрируются.
cat > "$PROFILES_DIR/pq.json" <<'JSON'
{"name":"pq","uuid":"11111111-1111-4111-8111-111111111111","port":31001,"transport":"xhttp","pq_enabled":true}
JSON
cat > "$PROFILES_DIR/routes.json" <<'JSON'
{"name":"routes","uuid":"22222222-2222-4222-8222-222222222222","routes":[{"port":31002,"transport":"tcp"}]}
JSON
cat > "$PROFILES_DIR/_bulk_seed.json" <<'JSON'
{"name":"_bulk_seed","bulk_seed":true,"port":31003,"transport":"tcp","pq_enabled":false}
JSON
filtered=$(_list_legacy_pq_profile_names)
[[ -z "$filtered" ]] || fail "фильтр пропустил PQ/multi-route/bulk-seed: $filtered"
noop_rc=0
_migrate_pq_all_profiles_2026 >/dev/null || noop_rc=$?
[[ "$noop_rc" -eq 1 ]] || fail "отфильтрованные профили: ожидался rc=1, получен $noop_rc"
[[ "$(cksum < "$CONFIG_FILE")" == "$config_before" ]] || fail "фильтрованный no-op изменил config.json"
echo "  ✓ поведение: PQ, multi-route и bulk-seed исключены без мутаций"

echo "✓ PQ migration static checks passed"
