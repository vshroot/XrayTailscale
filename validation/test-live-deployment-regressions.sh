#!/usr/bin/env bash
# Регрессии, найденные на живом VPS после развёртывания:
# 1) UFW LIMIT — валидное «открыто», а не «правила нет» (иначе статус-экран
#    ложно ругался и предлагал ненужную автопочинку на :80 и порту подписки).
# 2) Сервис подписки не должен умирать после серии быстрых рестартов
#    (SIGTERM от внешнего timeout уводил его в StartLimit → 502).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS="$ROOT/src/57-status.sh"
SUB="$ROOT/src/35-subscription.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck disable=SC1090
source "$STATUS"

echo "Checking UFW LIMIT is treated as open"

ufw() { cat /tmp/xt_ufw_sample.txt; }

printf 'Status: active\n\n22/tcp ALLOW Anywhere\n80/tcp LIMIT Anywhere\n443/tcp ALLOW Anywhere\n9443/tcp LIMIT Anywhere\n' > /tmp/xt_ufw_sample.txt
state=$(_status_ufw_state 9443)
[[ "$state" == "active, ports open"* ]] \
  || fail "LIMIT ports reported as: $state"
echo "  ok LIMIT 80/9443 → «порты открыты»"

# Обратная ветка обязана продолжать работать: реальное отсутствие правил ловится.
printf 'Status: active\n\n22/tcp ALLOW Anywhere\n443/tcp ALLOW Anywhere\n' > /tmp/xt_ufw_sample.txt
state=$(_status_ufw_state 9443)
[[ "$state" == *"NO rules"* && "$state" == *"80"* && "$state" == *"9443"* ]] \
  || fail "missing rules not detected: $state"
echo "  ok реально отсутствующие правила всё ещё ловятся"

# Мульти-порт и ALLOW не сломались.
printf 'Status: active\n\n80,443/tcp ALLOW Anywhere\n9443/tcp LIMIT Anywhere\n' > /tmp/xt_ufw_sample.txt
state=$(_status_ufw_state 9443)
[[ "$state" == "active, ports open"* ]] \
  || fail "multi-port ALLOW broke: $state"
echo "  ok мульти-порт 80,443/tcp ALLOW"

# Диагностика :80 тоже не должна считать LIMIT закрытым.
printf 'Status: active\n\n80/tcp LIMIT Anywhere\n' > /tmp/xt_ufw_sample.txt
_status_diag_7_port80 >/dev/null 2>&1 || fail "diag_7 failed on LIMIT 80/tcp"
echo "  ok диагностика :80 принимает LIMIT"

rm -f /tmp/xt_ufw_sample.txt

echo "Checking subscription service restart policy"

grep -q 'Restart=always' "$SUB" \
  || fail "subscription unit does not use Restart=always (SIGTERM would leave it dead)"
grep -q 'StartLimitIntervalSec=0' "$SUB" \
  || fail "subscription unit can still die on StartLimit after rapid restarts"

# Политика должна быть внутри unit-файла, а не в комментарии рядом.
awk '/\[Service\]/{s=1} s&&/Restart=always/{r=1} s&&/StartLimitIntervalSec=0/{l=1} END{exit !(r&&l)}' "$SUB" \
  || fail "restart policy not inside the [Service] section"

echo "  ok Restart=always + StartLimitIntervalSec=0 в [Service]"
echo "PASS test-live-deployment-regressions.sh"
