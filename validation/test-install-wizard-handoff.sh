#!/usr/bin/env bash
# Статические проверки Фазы 5: install.sh ведёт на мастер, доки соответствуют
# новому UX (нет ссылок на удалённое 16-пунктное меню).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
README="$ROOT/README.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "Checking install.sh wizard hand-off"

[[ -f "$INSTALL" ]] || fail "install.sh not found"
bash -n "$INSTALL" || fail "install.sh has syntax errors"
bash -n "$ROOT/xraytailscale" || fail "xraytailscale has syntax errors"

# Интерактивный запуск обязан предлагать мастер, а не только печатать меню.
grep -q 'xraytailscale wizard' "$INSTALL" || fail "install.sh does not invoke the wizard"
grep -q '\[\[ -t 0 \]\]' "$INSTALL" || fail "install.sh does not gate the wizard on a tty"
grep -q 'XT_DOMAIN' "$INSTALL" || fail "XT_DOMAIN non-interactive path lost"

# Порядок: сначала финальное сообщение, потом первичная настройка
# (иначе clear финального сообщения стирает ссылку/QR мастера).
final_line=$(grep -n 'INSTALLATION COMPLETED' "$INSTALL" | head -1 | cut -d: -f1)
wizard_line=$(grep -n 'xraytailscale wizard' "$INSTALL" | head -1 | cut -d: -f1)
[[ -n "$final_line" && -n "$wizard_line" ]] || fail "cannot locate install.sh sections"
[[ "$wizard_line" -gt "$final_line" ]] || fail "wizard runs before the final banner (its link would be cleared)"

# Старая реклама 8443 как «альтернативного порта» убрана: порт выбирается динамически.
grep -q '8443/tcp${NC} - Альтернативный порт' "$INSTALL" && fail "install.sh still advertises a hardcoded 8443"

echo "Checking README matches the new UX"

[[ -f "$README" ]] || fail "README.md not found"

grep -q 'status screen' "$README" || fail "README does not describe the status screen"
grep -q 'More' "$README" || fail "README does not describe the More section"
grep -q 'setup wizard' "$README" || fail "README does not describe the first-run wizard"

# Ни одного упоминания старых пунктов меню.
for stale in '`9`' '`10`' '`11`' '`12`' '`13`' '`14`' '`15`' '`16`' '9) HAPP subscription' '16) Self-steal' '11) Update Xray-core'; do
  grep -qF -- "$stale" "$README" && fail "README still references removed menu item: $stale"
done

# Bypass и outbound описаны как часть каскада.
grep -q 'Cascade / upstream' "$README" || fail "README does not show cascade as the parent menu"

echo "  ok install.sh + README"
echo "PASS test-install-wizard-handoff.sh"
