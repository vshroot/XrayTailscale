#!/usr/bin/env bash
# Поведенческая проверка: невалидный ввод не должен вешать мастер навсегда.
# Грузим ТОЛЬКО src/56-wizard.sh с заглушками вместо остальных модулей —
# иначе 00-core.sh требует root и ключи Reality ещё до самой функции.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIZARD="$ROOT/src/56-wizard.sh"
[[ -f "$WIZARD" ]] || { echo "FAIL: $WIZARD not found" >&2; exit 1; }

PROBE_DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_wizard_probe_driver.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Отдельный файл-драйвер: иначе вложенные кавычки в bash -c ломают разбор.
cat > "$PROBE_DRIVER" <<'DRIVER'
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""; NC=""
source "$1"
# Заглушки ПОСЛЕ загрузки: модуль определяет свои версии этих функций.
_wizard_has_root() { return 0; }
_wizard_print_header() { :; }
_wizard_step_banner() { :; }
_wizard_state_set() { :; }
_wizard_state_get() { echo ""; }
_wizard_state_clear() { :; }
_wizard_confirm_retry_or_exit() { return 1; }
validate_server_domain() { return 1; }
_selfsteal_dns_check() { return 1; }
get_server_ip() { echo "127.0.0.1"; }
# Шаг 1 не цель теста: подменяем бинарники окружения через PATH, чтобы дойти
# до ввода домена/email/имени на macOS, где нет xray/systemctl/ufw/ss.
stub="/tmp/xt_wiz_stubbin"
mkdir -p "$stub"
for b in xray systemctl ufw; do
  printf '%s\n' '#!/bin/sh' 'echo "Status: active"' > "$stub/$b"
  chmod +x "$stub/$b"
done
# ss должен молчать: пустой вывод = «порт 443 свободен», иначе шаг 1 падает.
printf '%s\n' '#!/bin/sh' 'exit 0' > "$stub/ss"
chmod +x "$stub/ss"
export PATH="$stub:$PATH"
WIZARD_STATE_FILE=/tmp/xt_wiz_state_probe
WIZARD_DONE_FILE=/tmp/xt_wiz_done_probe
rm -f "$WIZARD_STATE_FILE" "$WIZARD_DONE_FILE"
run_first_run_wizard
DRIVER

trap 'rm -f "$PROBE_DRIVER"' EXIT

probe() {
  local label="$1" first_answer="$2" junk="$3"
  local out rc
  out=$(
    { printf '%s\n' "$first_answer"; yes "$junk"; } \
      | timeout 40 bash "$PROBE_DRIVER" "$WIZARD" 2>&1
  )
  rc=$?
  if [[ "$rc" -eq 124 ]]; then
    fail "$label: мастер завис (timeout) на бесконечном невалидном вводе"
  fi
  if ! grep -q "Слишком много попыток" <<<"$out"; then
    echo "$out" | tail -6
    fail "$label: лимит попыток не сработал (rc=$rc)"
  fi
  echo "  ok $label — цикл оборвался лимитом (rc=$rc)"
}

echo "Checking wizard input loops are bounded"
probe "email" "н" "not-an-email"
probe "domain" "д" "not a domain!!"
probe "user name" $'н\nadmin@example.com' "bad name!!"

echo "PASS test-wizard-input-limits.sh"
