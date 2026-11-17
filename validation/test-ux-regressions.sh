#!/usr/bin/env bash
# Регрессии UX, найденные на живом VPS (185.112.144.206) при приёмке:
# 1) QR пропадал: qrencode печатал QR, но следующий экран делал `clear`
#    (show_ascii) — QR исчезал до того, как пользователь успевал его отсканировать.
#    Теперь после QR всегда идёт пауза, и QR-блок не стирается сам.
# 2) Из «создания пользователя» нельзя было выйти назад: имя вводилось и
#    профиль создавался сразу, без подтверждения и без отмены.
# 3) Массовая генерация была спрятана за 4 уровня вложенности — на главном
#    экране её не было.
# 4) Подписка отдавалась по IP с портом, хотя домен уже обслуживает валидный
#    LE-сертификат: должна быть возможность отдать подписку по домену.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS="$ROOT/src/57-status.sh"
SUB="$ROOT/src/35-subscription.sh"
CORE="$ROOT/src/00-core.sh"
BULK="$ROOT/src/40-bulk-happ.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "Checking QR is never wiped by the next screen"

# Общий хелпер QR с паузой — все места показа QR обязаны использовать его.
if ! grep -q '^_print_qr_block()' "$ROOT/src/"*.sh 2>/dev/null; then
  fail "no shared _print_qr_block() helper"
fi

# Каждый вызов qrencode в src/ обязан идти через хелпер (иначе QR снова пропадёт).
# Сам хелпер (_print_qr_block) — единственное место, где qrencode разрешён напрямую.
helper_src=$(grep -rl '^_print_qr_block()' "$ROOT/src/" | head -1)
raw_calls=$(grep -rn 'qrencode -t ANSIUTF8' "$ROOT/src/" | \
  grep -v '_print_qr_block' | grep -v "^${helper_src}:" || true)
if [[ -n "$raw_calls" ]]; then
  echo "  raw qrencode calls outside the helper:" >&2
  echo "$raw_calls" >&2
  fail "qrencode must only be called from _print_qr_block"
fi

# Хелпер обязан печатать QR И ждать Enter — иначе следующий clear() его сотрёт.
helper_file=$(grep -rl '^_print_qr_block()' "$ROOT/src/" | head -1)
helper_body=$(sed -n '/^_print_qr_block()/,/^}/p' "$helper_file")
echo "$helper_body" | grep -q 'qrencode' || fail "helper does not render the QR"
echo "$helper_body" | grep -qE 'read -r' || fail "helper does not pause after the QR (screen would be cleared)"
echo "  ok _print_qr_block() renders + pauses"

echo "Checking add-user flow can be cancelled and confirmed"

add_body=$(sed -n '/^_status_add_user()/,/^}/p' "$STATUS")
echo "$add_body" | grep -qE 'cancel|0\)' || fail "add-user has no cancel path"
echo "$add_body" | grep -qiE 'confirm|create\?' || fail "add-user creates without confirmation"
echo "  ok cancel + confirmation present"

echo "Checking bulk generation is reachable from the status screen"

status_body=$(sed -n '/^status_screen()/,/^}/p' "$STATUS")
echo "$status_body" | grep -qiE 'bulk' || fail "status screen does not expose bulk user generation"
grep -q '^bulk_happ_users_menu()' "$BULK" || fail "bulk_happ_users_menu() missing"
echo "  ok bulk generation reachable from status screen"

echo "Checking domain-mode subscription support"

grep -q '^install_subscription_selfsteal_domain()' "$SUB" || fail "no domain-mode subscription installer"
grep -q 'selfsteal_domain' "$SUB" || fail "domain-mode installer does not use the self-steal domain"
# Базовый URL должен уметь отдавать домен без порта.
grep -q '_subscription_base_url' "$ROOT/src/05-profile-utils.sh" || fail "base url helper missing"
echo "  ok domain-mode subscription installer present"

echo "Checking Karing/sing-box get a base64 subscription (not raw vless://)"
# Karing (sing-box) ожидает base64-список. Без этого он получает сырой vless://
# и не завершает парсинг — на iOS это выглядело как TimeoutException через 60 с.
echo "$SUB" >/dev/null
if ! grep -qE '\*"karing"\*' "$SUB"; then
  fail "handler does not special-case the Karing user-agent for base64"
fi
grep -qE '\*"sing-box"\*|\*"singbox"\*' "$SUB" || fail "no sing-box base64 branch"
echo "  ok Karing/sing-box base64 branch present"

echo "PASS test-ux-regressions.sh"
