#!/bin/bash
# test-update-xray-core-sync.sh
# Phase 5 sync-test: проверяет что inline-копии update_xray_core() в трех файлах
# (xraytailscale, update.sh, install.sh) идентичны после нормализации.
#
# Если расходятся — exit 1 с diff'ом. CI/pre-commit guard для REQ-B03.
#
# Usage:  bash validation/test-update-xray-core-sync.sh
#         from any cwd. Использует REPO_ROOT.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Цвета (ASCII fallback если нет terminal)
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

# Извлечение функции из файла + нормализация (strip comments, blank lines, leading whitespace).
# Awk детектит начало функции по `^FUNCNAME() {` и конец по `^}` на отдельной строке.
extract_fn() {
  local file="$1"
  local fn="$2"
  awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" { in_fn = 1; next }
    in_fn && $0 ~ "^\\}$" { in_fn = 0; next }
    in_fn { print }
  ' "$file" | sed -E '
    s/^[[:space:]]+//;
    s/[[:space:]]+$//;
    /^[[:space:]]*#/d;
    /^[[:space:]]*$/d;
  '
}

# Сравнить функцию между парой файлов
compare_pair() {
  local fn="$1"
  local file_a="$2"
  local file_b="$3"

  local body_a body_b
  body_a=$(extract_fn "$file_a" "$fn")
  body_b=$(extract_fn "$file_b" "$fn")

  if [[ -z "$body_a" ]]; then
    echo -e "${RED}✗ Функция $fn не найдена в $file_a${NC}"
    return 1
  fi
  if [[ -z "$body_b" ]]; then
    echo -e "${RED}✗ Функция $fn не найдена в $file_b${NC}"
    return 1
  fi

  if ! diff <(echo "$body_a") <(echo "$body_b") > /dev/null; then
    echo -e "${RED}✗ $fn расходится: $file_a vs $file_b${NC}"
    diff <(echo "$body_a") <(echo "$body_b") | head -40
    return 1
  fi

  echo -e "${GREEN}  ✓ $fn идентична: $(basename "$file_a") vs $(basename "$file_b")${NC}"
  return 0
}

echo -e "${YELLOW}Проверка sync update_xray_core() между xraytailscale/update.sh/install.sh${NC}"

UPDATE_SH="$REPO_ROOT/update.sh"
INSTALL_SH="$REPO_ROOT/install.sh"
XRAYTAILSCALE="$REPO_ROOT/xraytailscale"

# Проверка всех 4 функций (main + 3 helper'а), 3 пары файлов = 12 сравнений.
# Для прохождения теста все должны совпадать.
fns=(update_xray_core _fetch_latest_tag _print_manual_install_hint _cleanup_xray_backups)
fails=0

for fn in "${fns[@]}"; do
  echo -e "${YELLOW}- $fn:${NC}"
  compare_pair "$fn" "$UPDATE_SH" "$INSTALL_SH" || ((fails++))
  compare_pair "$fn" "$UPDATE_SH" "$XRAYTAILSCALE" || ((fails++))
  compare_pair "$fn" "$INSTALL_SH" "$XRAYTAILSCALE" || ((fails++))
done

if [[ $fails -gt 0 ]]; then
  echo -e "${RED}✗ Sync-test провалился: $fails расхождений${NC}"
  exit 1
fi

echo -e "${GREEN}✓ Sync-test прошел: все 4 функции идентичны во всех 3 файлах${NC}"
