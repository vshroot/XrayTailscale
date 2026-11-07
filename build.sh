#!/bin/bash
# build.sh — собрать single-file xraytailscale из модулей src/*.sh
#
# Модули конкатенируются в порядке сортировки имён (00-… → 99-…).
# Рантайм и деплой НЕ меняются: install.sh/update.sh по-прежнему
# скачивают один собранный файл xraytailscale из корня репозитория.
#
# Использование:
#   ./build.sh              # пересобрать ./xraytailscale
#   ./build.sh /tmp/xt      # собрать в указанный путь (для проверок)
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-xraytailscale}"
TMP=$(mktemp /tmp/xraytailscale-build.XXXXXX)
trap 'rm -f "$TMP"' EXIT

cat src/*.sh > "$TMP"
bash -n "$TMP"
chmod +x "$TMP"
cp "$TMP" "$OUT"
chmod +x "$OUT"
echo "✓ Собран $OUT ($(wc -l < "$OUT" | tr -d ' ') строк)"
