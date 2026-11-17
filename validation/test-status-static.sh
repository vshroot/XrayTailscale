#!/bin/bash
# test-status-static.sh — статус-экран настроенного сервера (src/57-status.sh)
# + диагностика с автопочинкой.
#
# Фиксируемые инварианты:
#   1. Модуль существует, синтаксически валиден, собирается между 56 и 60.
#   2. Публичный контракт: status_screen / status_render_summary /
#      diagnose_and_repair (+ хелперы).
#   3. URL подписки строится только через _subscription_base_url: в файле нет
#      ручной склейки «схема://хост:порт/sub/…» (кроме локального зонда
#      https://127.0.0.1, который по определению не публичный URL).
#   4. Каждая функция, вызывающая внешнюю утилиту (ss/curl/nginx/systemctl/
#      openssl/ufw/certbot/journalctl/getent/qrencode/timeout/date),
#      содержит guard `command -v` на неё — «голых» вызовов нет.
#   5. Переиспользование существующего кода вместо дублей:
#      create_profile_all_routes/…_happ_print_subscription_url_for_profile/
#      _subscription_find_free_port/open_firewall_port/safe_restart_xray.
#   6. diagnose_and_repair содержит ровно 7 пронумерованных проверок.
#   7. Поведение: сводка на пустом окружении не падает; режим self-steal
#      определяется по маркеру; URL собирается через base_url; _diag_step
#      чинит-и-перепроверяет; автоперенос порта подписки переписывает nginx.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xraytailscale-status.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

fail() {
  echo "✗ $*" >&2
  exit 1
}

STATUS="src/57-status.sh"

# Извлечь тело функции: от ^name() до следующего определения на нулевом отступе.
_fn_body() {
  local file="$1" name="$2"
  awk -v fn="^${name}\\(\\)" '
    $0 ~ fn {flag=1; print; next}
    flag && /^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{/ {exit}
    flag {print}
  ' "$file"
}

echo "Проверка статус-экрана и диагностики (src/57-status.sh)"

# ── 1. Файл и сборка ───────────────────────────────────────
[[ -f "$STATUS" ]] || fail "$STATUS не найден"
bash -n "$STATUS" || fail "$STATUS не проходит bash -n"

mod_order=$(ls src/*.sh | sed 's|src/||')
menu_pos=$(grep -n '^55-main-menu\.sh$' <<< "$mod_order" | cut -d: -f1)
wiz_pos=$(grep -n '^56-wizard\.sh$' <<< "$mod_order" | cut -d: -f1)
status_pos=$(grep -n '^57-status\.sh$' <<< "$mod_order" | cut -d: -f1)
create_pos=$(grep -n '^60-profile-create\.sh$' <<< "$mod_order" | cut -d: -f1)
[[ -n "$menu_pos" && -n "$wiz_pos" && -n "$status_pos" && -n "$create_pos" ]] || \
  fail "не найдены модули 55/56/57/60"
[[ "$menu_pos" -lt "$wiz_pos" && "$wiz_pos" -lt "$status_pos" && "$status_pos" -lt "$create_pos" ]] || \
  fail "порядок нарушен: 55=$menu_pos 56=$wiz_pos 57=$status_pos 60=$create_pos"

bash build.sh "$WORKDIR/xraytailscale" >/dev/null || fail "build.sh с новым модулем упал"
bash -n "$WORKDIR/xraytailscale" || fail "собранный бандл не проходит bash -n"
grep -q '^status_screen()' "$WORKDIR/xraytailscale" || fail "status_screen не попал в бандл"
grep -q '^diagnose_and_repair()' "$WORKDIR/xraytailscale" || fail "diagnose_and_repair не попал в бандл"
echo "  ✓ модуль на месте (55 → 56 → 57 → 60), бандл собирается"

# shellcheck disable=SC1091
source "$WORKDIR/xraytailscale"

# ── 2. Публичный контракт ──────────────────────────────────
for fn in status_screen status_render_summary diagnose_and_repair; do
  grep -q "^${fn}()" "$STATUS" || fail "$STATUS: не определена ${fn}()"
done
# Сводка отделена от меню: status_render_summary не должна печатать меню/читать ввод.
summary_body=$(_fn_body "$STATUS" status_render_summary)
[[ -n "$summary_body" ]] || fail "не удалось извлечь тело status_render_summary"
if grep -qE '(^|[^a-zA-Z_])read -r (choice|ans)' <<< "$summary_body"; then
  fail "status_render_summary не должна читать ввод (меню живёт в status_screen)"
fi
if grep -q 'Добавить пользователя' <<< "$summary_body"; then
  fail "status_render_summary печатает меню — должно быть только сводка"
fi
echo "  ✓ контракт: status_render_summary (только сводка) + status_screen + diagnose_and_repair"

# ── 3. URL подписки: только через _subscription_base_url ───
# Каждая строка с «/sub/» обязана либо идти через _subscription_base_url,
# либо быть локальным зондом на 127.0.0.1 (не публичный URL).
bad_url_lines=$(grep -n '/sub/' "$STATUS" | grep -v '^[0-9]*:[[:space:]]*#' | \
  grep -v '_subscription_base_url' | grep -v '127\.0\.0\.1' || true)
if [[ -n "$bad_url_lines" ]]; then
  fail "ручная склейка URL подписки (нужен _subscription_base_url):${bad_url_lines}"
fi
# Никакой собственной сборки схемы/хоста.
if grep -qE '(echo|printf)[^#]*"(https?|http)://\$' "$STATUS"; then
  fail "своя сборка http(s)://<хост> в URL подписки"
fi
grep -q '_subscription_base_url' "$STATUS" || fail "модуль не использует _subscription_base_url"
grep -q '^_status_profile_sub_url()' "$STATUS" || fail "нет единой точки сборки URL (_status_profile_sub_url)"
echo "  ✓ URL подписки собирается через _subscription_base_url (ручного /sub/ нет)"

# ── 4. Переиспользование существующего кода ────────────────
grep -qF 'create_profile_all_routes "$user_name" "no_pause" "hide_subscription"' "$STATUS" || \
  fail "добавление пользователя должно идти через create_profile_all_routes <name> no_pause hide_subscription"
grep -q '_happ_print_subscription_url_for_profile' "$STATUS" || \
  fail "модуль не переиспользует _happ_print_subscription_url_for_profile"
grep -q '_list_visible_profile_names' "$STATUS" || fail "модуль не переиспользует _list_visible_profile_names"
grep -q '_subscription_find_free_port' "$STATUS" || fail "автоперенос порта должен звать _subscription_find_free_port"
grep -q 'open_firewall_port' "$STATUS" || fail "модуль не открывает порт через open_firewall_port"
grep -q 'safe_restart_xray' "$STATUS" || fail "починка Xray должна идти через safe_restart_xray"
grep -qF '"$user_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$' "$STATUS" || \
  fail "нет валидации имени пользователя ^[a-zA-Z0-9][a-zA-Z0-9_-]*$"
grep -qF '"$PROFILES_DIR/${user_name}.json"' "$STATUS" || \
  fail "нет проверки занятости имени профиля"
echo "  ✓ переиспользованы create_profile_all_routes / happ-URL / find_free_port / safe_restart_xray"

# ── 5. Нет «голых» вызовов внешних утилит ──────────────────
TOOLS="ss curl nginx systemctl openssl ufw certbot journalctl getent qrencode timeout date"
fn_names=$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$STATUS" | sed 's|()||' | sort -u)
unguarded=""
for fn in $fn_names; do
  body=$(_fn_body "$STATUS" "$fn")
  for tool in $TOOLS; do
    # Строки-вызовы: имя утилиты как команда (не в echo/комментарии/строке-подсказке).
    calls=$(printf '%s\n' "$body" | grep -vE '^[[:space:]]*#' | grep -v 'echo' | \
      grep -E "(^|[[:space:]!\$(|])${tool}[[:space:]]+[-%]" || true)
    [[ -n "$calls" ]] || continue
    if ! printf '%s\n' "$body" | grep -q "command -v ${tool}"; then
      unguarded="${unguarded}${fn}→${tool}; "
    fi
  done
done
if [[ -n "$unguarded" ]]; then
  fail "вызовы без guard'а command -v: ${unguarded}"
fi
echo "  ✓ все внешние вызовы защищены command -v (проверено по $(wc -w <<< "$fn_names" | tr -d ' ') функциям)"

# ── 6. Семь проверок диагностики ──────────────────────────
diag_body=$(_fn_body "$STATUS" diagnose_and_repair)
[[ -n "$diag_body" ]] || fail "не удалось извлечь тело diagnose_and_repair"
for n in 1 2 3 4 5 6 7; do
  grep -qE "_diag_step ${n} " <<< "$diag_body" || fail "diagnose_and_repair: нет шага ${n}"
  grep -q "^_status_diag_${n}_" "$STATUS" || fail "нет check-функции для проверки ${n}"
  grep -q "^_status_repair_${n}_" "$STATUS" || fail "нет repair-функции для проверки ${n}"
done
[[ "$(grep -cE '_diag_step [0-9]+ ' <<< "$diag_body")" -eq 7 ]] || \
  fail "diagnose_and_repair должен содержать ровно 7 шагов"
grep -q 'Исправлено: ' "$STATUS" || fail "нет итоговой сводки «Исправлено: N, осталось проблем: M»"
grep -q 'Починить' "$STATUS" || fail "нет предложения автопочинки"
grep -q '_status_manual_hints' "$STATUS" || fail "нет точных команд для ручной проверки"
echo "  ✓ 7 проверок: check + repair + ручные подсказки для каждой"

# ── 7. Поведение: сводка на пустом окружении ──────────────
EMPTY="$WORKDIR/empty"
mkdir -p "$EMPTY/profiles"

_blank_env() {
  CONFIG_FILE="$EMPTY/config.json"
  PROFILES_DIR="$EMPTY/profiles"
  STATUS_SUB_MARKER="$EMPTY/.subscription_installed"
  STATUS_SUB_PORT_FILE="$EMPTY/.subscription_port"
  STATUS_SUB_MODE_FILE="$EMPTY/.subscription_mode"
  STATUS_SELFSTEAL_DOMAIN_FILE="$EMPTY/.selfsteal_domain"
  STATUS_SELFSTEAL_PORT_FILE="$EMPTY/.selfsteal_backend_port"
  STATUS_NGINX_SUB_SITE="$EMPTY/nginx-sub"
  STATUS_LE_LIVE_DIR="$EMPTY/le"
  STATUS_SUB_DOMAIN_FILE="$EMPTY/.subscription_domain"
  SERVER_DOMAIN_FILE="$EMPTY/.server_domain"
}
_blank_env

set -u
out=$(_blank_env; status_render_summary 2>"$EMPTY/err") && rc=0 || rc=1
err=$(cat "$EMPTY/err")
set +u
if grep -qE 'unbound variable|command not found|syntax error' <<< "$err"; then
  fail "status_render_summary падает на пустом окружении: ${err}"
fi
[[ "$rc" -eq 0 || "$rc" -eq 1 ]] || fail "status_render_summary вернула rc=${rc}"
grep -q 'Режим:' <<< "$out" || fail "сводка без строки «Режим»"
grep -q 'Reality по IP' <<< "$out" || fail "пустое окружение должно давать режим «Reality по IP»"
grep -q 'не установлена' <<< "$out" || fail "сводка не сообщает об отсутствии подписки"
[[ "$rc" -eq 1 ]] || fail "сводка с проблемами должна возвращать 1"
echo "  ✓ сводка на пустом окружении не падает (rc=1, без unbound/command not found)"

# ── 7b. Режим self-steal по маркеру ───────────────────────
echo "example.com" > "$EMPTY/.selfsteal_domain"
out=$( _blank_env; status_render_summary 2>/dev/null || true )
grep -q 'self-steal (example.com)' <<< "$out" || fail "маркер .selfsteal_domain не переключил режим на self-steal"
rm -f "$EMPTY/.selfsteal_domain"
echo "  ✓ режим определяется: маркер self-steal → «self-steal (<домен>)»"

# ── 7c. Сборка URL профиля ────────────────────────────────
mkdir -p "$EMPTY/profiles"
printf '%s\n' '{"name":"user-001","sub_token":"0123456789abcdef0123456789abcdef"}' \
  > "$EMPTY/profiles/user-001.json"
url=$( _blank_env
  _subscription_base_url() { echo "https://203.0.113.10:8443"; }
  export -f _subscription_base_url 2>/dev/null || true
  _status_profile_sub_url user-001 )
[[ "$url" == "https://203.0.113.10:8443/sub/0123456789abcdef0123456789abcdef" ]] || \
  fail "_status_profile_sub_url вернула '${url}' (ожидался base_url + /sub/<token>)"
printf '%s\n' '{"name":"bad"}' > "$EMPTY/profiles/bad.json"
set +e
( _blank_env; _status_profile_sub_url bad >/dev/null 2>&1 )
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "_status_profile_sub_url должна падать без валидного sub_token"
echo "  ✓ URL профиля = _subscription_base_url + /sub/<token>; без токена — ошибка"

# ── 7d. Сертификат: нет файла → return 1 (без падения) ────
set +e
( _blank_env; _status_cert_days example.com >/dev/null 2>&1 )
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "_status_cert_days должна возвращать 1 при отсутствии файла"
echo "  ✓ _status_cert_days: отсутствие сертификата → 1, без падения"

# ── 8. Поведение: _diag_step чинит и перепроверяет ────────
# Счётчики живут в текущем shell, поэтому проба печатает их хвостом вывода
# (иначе $(...) выполняет функцию в subshell и счётчик не виден снаружи).
_state=0
_check()   { [[ "$_state" -eq 1 ]]; }
_repair()  { _state=1; return 0; }
_step_probe() {
  local num="$1" title="$2" repair_fn="$3"
  _diag_step "$num" "$title" _check "$repair_fn"
  echo "COUNTERS problems=${_DIAG_PROBLEMS} fixed=${_DIAG_FIXED}"
}
out=$( _step_probe 1 "тестовая проверка" _repair <<< "1" )
grep -q '✓ Исправлено' <<< "$out" || fail "_diag_step не подтвердил починку: ${out}"
grep -q 'COUNTERS problems=1 fixed=1' <<< "$out" || fail "_diag_step не увеличил счётчик исправлений: ${out}"

# Отказ от починки → ручные подсказки, проблемы остаются.
_state=0
out=$( _step_probe 2 "тестовая проверка" _repair <<< "2" )
grep -q 'Что проверить вручную' <<< "$out" || fail "_diag_step не показал ручные команды при пропуске"
grep -q 'fixed=0' <<< "$out" || fail "пропуск починки не должен увеличивать счётчик исправлений: ${out}"

# Неудачная починка → «не удалась» + ручные команды.
_state=0
_repair_fail() { return 1; }
out=$( _step_probe 3 "тестовая проверка" _repair_fail <<< "1" )
grep -q 'Автопочинка не удалась' <<< "$out" || fail "_diag_step не сообщил о неудачной починке"
echo "  ✓ _diag_step: починка → перепроверка → «Исправлено» / ручные команды"

# ── 8b. diagnose_and_repair: всё зелёное → «Всё в порядке» ─
_all_ok_probe() {
  _status_diag_1_xray()       { return 0; }
  _status_diag_2_port443()    { return 0; }
  _status_diag_3_subscription() { return 0; }
  _status_diag_4_subport()    { return 0; }
  _status_diag_5_subhttp()    { return 0; }
  _status_diag_6_cert()       { return 0; }
  _status_diag_7_port80()     { return 0; }
  _status_pause() { :; }
  diagnose_and_repair
}
out=$(_all_ok_probe < /dev/null)
grep -q 'ВСЁ В ПОРЯДКЕ' <<< "$out" || fail "diagnose_and_repair не показал «Всё в порядке» при 7/7"
grep -q 'Исправлено: 0, осталось проблем: 0' <<< "$out" || fail "итоговая сводка неверна: ${out}"
echo "  ✓ diagnose_and_repair: 7/7 → «Всё в порядке», итог 0/0"

# ── 8b2. Смешанный прогон: 1 починено, 1 пропущено ────────
# Проверяем сквозной контракт счётчиков: «Исправлено: 1, осталось проблем: 1».
_mixed_probe() {
  local fixed=0
  _status_diag_1_xray()       { return 0; }
  _status_diag_2_port443()    { [[ "$fixed" -eq 1 ]] && return 0; _STATUS_REASON="занят"; return 1; }
  _status_repair_2_port443()  { fixed=1; return 0; }
  _status_diag_3_subscription() { return 0; }
  _status_diag_4_subport()    { return 0; }
  _status_diag_5_subhttp()    { _STATUS_REASON="HTTP 502"; return 1; }
  _status_repair_5_subhttp()  { return 1; }   # не чинится
  _status_diag_6_cert()       { return 0; }
  _status_diag_7_port80()     { return 0; }
  _status_pause() { :; }
  # 2 → «Починить», 2 → «Пропустить», остальное не спрашивается.
  diagnose_and_repair <<< $'1\n2'
}
set +e
out=$(_mixed_probe 2>&1)
rc=$?
set -e
grep -q 'Исправлено: 1, осталось проблем: 1' <<< "$out" || \
  fail "счётчики сквозного прогона неверны: $(grep 'Исправлено' <<< "$out")"
if grep -q 'ВСЁ В ПОРЯДКЕ' <<< "$out"; then
  fail "«Всё в порядке» при остаточной проблеме"
fi
[[ "$rc" -eq 1 ]] || fail "diagnose_and_repair с остатком должна возвращать 1 (получено $rc)"
echo "  ✓ сквозной прогон: 1 починка + 1 остаток → «Исправлено: 1, осталось проблем: 1», rc=1"

# ── 8c. Автоперенос порта подписки ────────────────────────
MOVE="$WORKDIR/move"
mkdir -p "$MOVE/profiles"
cat > "$MOVE/nginx-sub" <<'EOF'
server {
    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;
    server_name 203.0.113.10;
}
EOF
printf '%s\n' "8443" > "$MOVE/.subscription_port"
printf '%s\n' "8443" > "$MOVE/.selfsteal_backend_port"
printf '%s\n' '{"name":"user-001","sub_token":"0123456789abcdef0123456789abcdef"}' \
  > "$MOVE/profiles/user-001.json"

_move_probe() {
  CONFIG_FILE="$MOVE/config.json"
  PROFILES_DIR="$MOVE/profiles"
  STATUS_SUB_PORT_FILE="$MOVE/.subscription_port"
  STATUS_SELFSTEAL_PORT_FILE="$MOVE/.selfsteal_backend_port"
  STATUS_NGINX_SUB_SITE="$MOVE/nginx-sub"
  nginx() { return 0; }
  systemctl() { return 0; }
  open_firewall_port() { return 0; }
  _subscription_find_free_port() { echo 9443; }
  _subscription_base_url() { echo "https://203.0.113.10:9443"; }
  _status_move_subscription_port 8443
}
out=$(_move_probe)
grep -q 'listen 9443 ssl' "$MOVE/nginx-sub" || fail "nginx-конфиг не переписан на новый порт"
grep -q 'listen \[::\]:9443 ssl' "$MOVE/nginx-sub" || fail "IPv6-listen не переписан"
if grep -q '8443' "$MOVE/nginx-sub"; then
  fail "старый порт остался в nginx-конфиге"
fi
[[ "$(cat "$MOVE/.subscription_port")" == "9443" ]] || fail "маркер .subscription_port не обновлён"
grep -q 'ССЫЛКА ПОДПИСКИ ИЗМЕНИЛАСЬ\|ссылка подписки ИЗМЕНИЛАСЬ' <<< "$out" || \
  fail "не сообщено об изменении ссылки"
grep -q 'https://203.0.113.10:9443' <<< "$out" || fail "новая URL не перевыпущена через _subscription_base_url"
echo "  ✓ автоперенос подписки: listen main+[::] переписан, маркер обновлён, новая URL показана"

# ── 8d. local-only подписка — это ⚠, а не успех ────────────
# local_only означает «клиент снаружи подписку не заберёт», поэтому даже
# HTTP 200 локально не должен давать зелёный ✓.
_loc_probe() {
  echo 8080 > "$EMPTY/.subscription_port"
  echo local_only > "$EMPTY/.subscription_mode"
  touch "$EMPTY/.subscription_installed"
  _blank_env
  # ss/curl подменяем функциями: command -v видит функции, поэтому проверки
  # «есть ли утилита» проходят и на хостах без iproute2 (macOS).
  ss()        { echo 'LISTEN 0 511 127.0.0.1:8080 users:(("socat",pid=3))'; }
  curl()      { printf 200; }
  _status_port_listener() { echo 'LISTEN 0 511 127.0.0.1:8080 users:(("socat",pid=3))'; }
  status_render_summary
}
# status_render_summary возвращает 1 (есть ⚠) — под set -e это не ошибка теста.
out=$(_loc_probe 2>&1) || true
sub_line=$(grep 'Подписка:' <<< "$out" | head -1)
grep -q 'local-only' <<< "$sub_line" || fail "local-only подписка не помечена в сводке: ${sub_line}"
if grep -q '0;32m✓' <<< "$sub_line"; then
  fail "local-only подписка не должна быть зелёной ✓: ${sub_line}"
fi
rm -f "$EMPTY/.subscription_port" "$EMPTY/.subscription_mode" "$EMPTY/.subscription_installed"
echo "  ✓ local-only подписка помечается ⚠ (снаружи недоступна)"

# ── 9. Никаких хардкодов пути маркеров ────────────────────
# Пути заданы через ${VAR:-default} → тесты могут подменять (как в 56-wizard).
for var in STATUS_SUB_MARKER STATUS_SUB_PORT_FILE STATUS_SELFSTEAL_DOMAIN_FILE \
           STATUS_SELFSTEAL_PORT_FILE STATUS_NGINX_SUB_SITE STATUS_LE_LIVE_DIR; do
  grep -qE "^${var}=\"\\\$\\{${var}:-" "$STATUS" || \
    fail "${var} должен быть объявлен как \${${var}:-<default>} (override для тестов)"
done
echo "  ✓ пути маркеров переопределяемы через env"

# ── 10. main_menu маршрутизирует в status_screen ───────────
main_menu_body=$(_fn_body src/55-main-menu.sh main_menu)
[[ -n "$main_menu_body" ]] || fail "не удалось извлечь тело main_menu"
grep -qE '^[[:space:]]+status_screen[[:space:]]*$' <<< "$main_menu_body" || \
  fail "src/55-main-menu.sh: main_menu должен вызывать status_screen"
echo "  ✓ main_menu вызывает status_screen"

# ── 11. Консистентность конфиг/маркер при сбоях (находки quality-ревью) ──
# Инвариант: если перенос завершился НЕуспешно, конфиг nginx остаётся на
# старом порту И маркер .subscription_port остаётся на старом порту.
# Регрессия = «маркер на новом, nginx на старом».

_move_env() {
  local dir="$1"
  mkdir -p "$dir/profiles"
  printf '%s\n' "8443" > "$dir/.subscription_port"
  printf '%s\n' "8443" > "$dir/.selfsteal_backend_port"
  printf '%s\n' '{"name":"user-001","sub_token":"0123456789abcdef0123456789abcdef"}' \
    > "$dir/profiles/user-001.json"
  CONFIG_FILE="$dir/config.json"
  PROFILES_DIR="$dir/profiles"
  STATUS_SUB_PORT_FILE="$dir/.subscription_port"
  STATUS_SELFSTEAL_PORT_FILE="$dir/.selfsteal_backend_port"
  STATUS_NGINX_SUB_SITE="$dir/nginx-sub"
  _subscription_find_free_port() { echo 9443; }
  _subscription_base_url() { echo "https://203.0.113.10:9443"; }
}

# 11a. reload nginx падает → откат конфига, маркер не тронут, rc=1.
_dir="$WORKDIR/m-reload-fail"
_move_env "$_dir"
cat > "$_dir/nginx-sub" <<'EOF'
server {
    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;
}
EOF
rc=0
(
  _move_env "$_dir"
  nginx() { return 0; }
  systemctl() { return 1; }          # reload fails
  open_firewall_port() { return 0; }
  _status_move_subscription_port 8443 >/dev/null 2>&1
) || rc=$?
[[ $rc -ne 0 ]] || fail "11a: reload-fail должен вернуть ненулевой код"
grep -q 'listen 8443 ssl' "$_dir/nginx-sub" || fail "11a: конфиг не откачен на старый порт"
[[ "$(cat "$_dir/.subscription_port")" == "8443" ]] || fail "11a: маркер рассинхронизирован (ожидался 8443)"
echo "  ✓ 11a: падение reload → конфиг и маркер остаются на старом порту (консистентно)"

# 11b. firewall не открывается → откат конфига, маркер не тронут, rc=1.
_dir="$WORKDIR/m-fw-fail"
_move_env "$_dir"
cat > "$_dir/nginx-sub" <<'EOF'
server {
    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;
}
EOF
rc=0
(
  _move_env "$_dir"
  nginx() { return 0; }
  systemctl() { return 0; }
  open_firewall_port() { return 1; }          # firewall fails
  _status_move_subscription_port 8443 >/dev/null 2>&1
) || rc=$?
[[ $rc -ne 0 ]] || fail "11b: firewall-fail должен вернуть ненулевой код"
grep -q 'listen 8443 ssl' "$_dir/nginx-sub" || fail "11b: конфиг не откачен"
[[ "$(cat "$_dir/.subscription_port")" == "8443" ]] || fail "11b: маркер рассинхронизирован"
echo "  ✓ 11b: закрытый firewall → перенос откатывается (нет ложного «исправлено»)"

# 11c. sed не находит listen (конфиг без ssl) → preflight отказывает, rc=1,
# ничего не меняется.
_dir="$WORKDIR/m-no-listen"
_move_env "$_dir"
cat > "$_dir/nginx-sub" <<'EOF'
server {
    server_name 203.0.113.10;
}
EOF
rc=0
(
  _move_env "$_dir"
  nginx() { return 0; }
  systemctl() { return 0; }
  open_firewall_port() { return 0; }
  _status_move_subscription_port 8443 >/dev/null 2>&1
) || rc=$?
[[ $rc -ne 0 ]] || fail "11c: отсутствие listen должно давать rc=1"
[[ "$(cat "$_dir/.subscription_port")" == "8443" ]] || fail "11c: маркер не должен меняться"
echo "  ✓ 11c: preflight ловит «нет listen :8443» — маркер не уезжает на несуществующий порт"

# 11d. Нечисловой порт не уходит в sed (инъекция через маркер).
_dir="$WORKDIR/m-badport"
_move_env "$_dir"
printf '%s\n' 'server {' > "$_dir/nginx-sub"
printf '%s\n' 'listen 8443 ssl;' >> "$_dir/nginx-sub"
printf '%s\n' '}' >> "$_dir/nginx-sub"
rc=0
(
  _move_env "$_dir"
  nginx() { return 0; }
  systemctl() { return 0; }
  open_firewall_port() { return 0; }
  _status_move_subscription_port '8443; rm -rf /tmp' >/dev/null 2>&1
) || rc=$?
[[ $rc -ne 0 ]] || fail "11d: нечисловой порт должен отвергаться"
echo "  ✓ 11d: нечисловой порт отвергнут до sed/firewall"

# 11e. Дубликата _status_sub_port_conflict больше нет.
dup=$(grep -c '^_status_sub_port_conflict()' "$STATUS")
[[ "$dup" == "1" ]] || fail "11e: ожидалось ровно 1 определение _status_sub_port_conflict, найдено $dup"
echo "  ✓ 11e: мёртвый дубль _status_sub_port_conflict удалён"

echo "✓ status static checks passed"
