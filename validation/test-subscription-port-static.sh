#!/bin/bash
# test-subscription-port-static.sh — регрессионный тест реального инцидента:
# self-steal backend занял 127.0.0.1:8443, а HAPP-подписка выбрала тот же 8443
# без проверки listen → nginx reload упал, ссылка подписки мертва снаружи,
# пользователь не увидел ошибку.
#
# Проверяем (статически, по исходникам src/):
#   1. Есть helper _subscription_find_free_port, который проверяет реальный
#      listen (ss -tln) И self-steal backend port file (SELFSTEAL_PORT_FILE).
#   2. _select_subscription_port не содержит хардкод fallback `echo 8443`
#      (8443 допустим только в списке кандидатов helper'а).
#   3. _selfsteal_free_443_from_nginx не хардкодит `listen 8443 ssl` в sed —
#      порт берётся из _subscription_find_free_port.
#   4. Оба installer'а (ip_tls и public_tls) вызывают внешний self-check
#      подписки после установки.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

# Извлечь тело функции bash: от ^name() до следующего определения функции
# на нулевом отступе (надёжнее, чем ^}: внутри heredoc встречаются ^}).
_fn_body() {
  local file="$1" name="$2"
  awk -v fn="^${name}\\(\\)" '
    $0 ~ fn {flag=1; print; next}
    flag && /^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{/ {exit}
    flag {print}
  ' "$file"
}

echo "Проверка выбора порта HAPP-подписки (no hardcode 8443)"

# ── 1. helper _subscription_find_free_port ─────────────────
grep -q '^_subscription_find_free_port()' src/35-subscription.sh || \
  fail "src/35-subscription.sh: нет _subscription_find_free_port()"
helper_body=$(_fn_body src/35-subscription.sh _subscription_find_free_port)
[[ -n "$helper_body" ]] || fail "не удалось извлечь тело _subscription_find_free_port"
echo "$helper_body" | grep -q 'ss -tln' || \
  fail "_subscription_find_free_port не проверяет реальный listen (ss -tln)"
echo "$helper_body" | grep -q 'SELFSTEAL_PORT_FILE' || \
  fail "_subscription_find_free_port не учитывает self-steal backend port file"
echo "$helper_body" | grep -q '8443 9443 10443 11443 12443' || \
  fail "_subscription_find_free_port: список кандидатов должен быть 8443 9443 10443 11443 12443"
echo "  ✓ _subscription_find_free_port проверяет listen и self-steal backend"

# ── 2. _select_subscription_port без хардкода 8443 ─────────
select_body=$(_fn_body src/35-subscription.sh _select_subscription_port)
[[ -n "$select_body" ]] || fail "не удалось извлечь тело _select_subscription_port"
if echo "$select_body" | grep -q 'echo 8443'; then
  fail "_select_subscription_port: хардкод fallback 'echo 8443' (должен вызывать _subscription_find_free_port)"
fi
echo "$select_body" | grep -q '_subscription_find_free_port' || \
  fail "_select_subscription_port не использует _subscription_find_free_port"
echo "  ✓ _select_subscription_port без хардкода 8443"

# ── 3. self-steal перенос подписки без хардкода 8443 ───────
if grep -q 's/listen 443 ssl/listen 8443 ssl/' src/85-selfsteal.sh; then
  fail "src/85-selfsteal.sh: sed переноса подписки хардкодит 'listen 8443 ssl'"
fi
if grep -q "printf '8443" src/85-selfsteal.sh; then
  fail "src/85-selfsteal.sh: SUBSCRIPTION_PORT_FILE пишется хардкодом 8443"
fi
free443_body=$(_fn_body src/85-selfsteal.sh _selfsteal_free_443_from_nginx)
[[ -n "$free443_body" ]] || fail "не удалось извлечь тело _selfsteal_free_443_from_nginx"
echo "$free443_body" | grep -q '_subscription_find_free_port' || \
  fail "_selfsteal_free_443_from_nginx не использует _subscription_find_free_port"
echo "  ✓ перенос подписки self-steal без хардкода 8443"

# ── 4. post-install внешний self-check в обоих installer'ах ─
grep -q '^_subscription_external_selfcheck()' src/35-subscription.sh || \
  fail "src/35-subscription.sh: нет helper'а _subscription_external_selfcheck"
selfcheck_body=$(_fn_body src/35-subscription.sh _subscription_external_selfcheck)
echo "$selfcheck_body" | grep -q 'curl -sk --max-time' || \
  fail "_subscription_external_selfcheck должен делать curl -sk --max-time"
echo "$selfcheck_body" | grep -q 'Checking the subscription from outside' || \
  fail "_subscription_external_selfcheck: нет маркера 'Checking the subscription from outside'"

ip_body=$(_fn_body src/35-subscription.sh install_subscription_ip_tls)
[[ -n "$ip_body" ]] || fail "не удалось извлечь тело install_subscription_ip_tls"
echo "$ip_body" | grep -q '_subscription_external_selfcheck' || \
  fail "install_subscription_ip_tls не вызывает _subscription_external_selfcheck"

pub_body=$(_fn_body src/35-subscription.sh install_subscription_public_tls)
[[ -n "$pub_body" ]] || fail "не удалось извлечь тело install_subscription_public_tls"
echo "$pub_body" | grep -q '_subscription_external_selfcheck' || \
  fail "install_subscription_public_tls не вызывает _subscription_external_selfcheck"
echo "  ✓ оба installer'а вызывают внешний self-check подписки"

echo "✓ subscription port static checks passed"
