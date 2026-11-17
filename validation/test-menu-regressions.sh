#!/usr/bin/env bash
# Регрессии интеграционного ревью редизайна меню:
# 1) подписку можно создать/управлять из «Дополнительно» на настроенном
#    сервере (раньше happ_subscription_menu был недостижим ниоткуда);
# 2) update_command возвращает rc, а не exit — иначе пункт меню закрывал
#    весь менеджер вместо возврата в «Дополнительно».
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$ROOT/xraytailscale"

fail() { echo "FAIL: $*" >&2; exit 1; }

extract_fn() {
  local file="$1" name="$2"
  awk -v fn="$name" '
    $0 ~ "^" fn "\\(\\) \\{" { in_fn=1; depth=0 }
    in_fn {
      print
      n=gsub(/\{/, "{"); m=gsub(/\}/, "}")
      depth += n - m
      if (depth == 0) exit
    }
  ' "$file"
}

echo "Checking subscription reachability"

extra=$(extract_fn "$ROOT/src/57-status.sh" _status_extra_menu)
[[ -n "$extra" ]] || fail "_status_extra_menu not found"
grep -q 'happ_subscription_menu' <<<"$extra" \
  || fail "«Дополнительно» does not reach happ_subscription_menu (install path is lost)"

# Тело подменю содержит и установку, и управление — иначе пункт снова тупик.
sub_menu=$(extract_fn "$ROOT/src/35-subscription.sh" happ_subscription_menu)
grep -q 'install_subscription_ip_tls' <<<"$sub_menu" \
  || fail "happ_subscription_menu lost the install entry"
grep -q 'manage_subscription_menu' <<<"$sub_menu" \
  || fail "happ_subscription_menu lost the manage entry"
grep -q 'read -r c || return 0' <<<"$sub_menu" \
  || fail "happ_subscription_menu read is not EOF-safe"

# Подсказки не должны ссылаться на пункты удалённого 16-пунктного меню.
if grep -rn 'Сначала включите пункт\|через меню 16\|через меню 2\|пункт 11' "$ROOT/src/" ; then
  fail "stale references to removed menu items remain"
fi

echo "Checking update_command does not exit the manager"

upd=$(extract_fn "$ROOT/src/30-ui-update.sh" update_command)
[[ -n "$upd" ]] || fail "update_command not found"
grep -q 'exit \$rc' <<<"$upd" \
  && fail "update_command still uses exit \$rc — it would kill the whole menu"
grep -q 'return \$rc' <<<"$upd" \
  || fail "update_command does not return \$rc"

# Поведение, а не только grep: вызов update_command внутри меню не должен
# завершать родительский процесс, а rc обязан доходить до вызывающего.
tmpdir=$(mktemp -d /tmp/xt-menu-regression.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

export XRAYTAILSCALE_SOURCED=1
# shellcheck disable=SC1090
source "$BUNDLE"

update_xray_core() { return 2; }   # симулируем критическую ошибку обновления

set +e
(
  _status_pause() { return 0; }
  printf '8\n0\n' | _status_extra_menu >/dev/null 2>&1
)
menu_rc=$?
set -e
[[ "$menu_rc" -eq 0 ]] \
  || fail "_status_extra_menu died with rc=$menu_rc after the update item (parent was killed)"

set +e
update_command >/dev/null 2>&1
upd_rc=$?
set -e
[[ "$upd_rc" -eq 2 ]] \
  || fail "update_command returned rc=$upd_rc instead of propagating 2"

echo "  ok subscription menu reachable"
echo "  ok update_command returns instead of exiting"
echo "PASS test-menu-regressions.sh"
