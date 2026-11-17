#!/bin/bash
# test-wizard-static.sh — статические проверки мастера первичной настройки
# (src/56-wizard.sh) + email-override в install_subscription_ip_tls.
#
# Что фиксируем как инвариант:
#   1. Модуль существует, синтаксически валиден, лежит между 55 и 60 по сборке.
#   2. Публичный контракт: wizard_is_fresh_install / run_first_run_wizard /
#      wizard_command.
#   3. Шаг 4: _selfsteal_provision РАНЬШЕ install_subscription_ip_tls
#      (self-steal занимает :443 и backend-порт; обратный порядок даёт
#      конфликт server_name в nginx).
#   4. Мастер выставляет SUBSCRIPTION_LE_EMAIL перед вызовом installer'а —
#      email спрашивается один раз на шаге 2.
#   5. Первый пользователь создаётся через create_profile_all_routes с
#      "no_pause" (мастер не должен блокироваться на Enter внутри шага).
#   6. Завершение: .wizard_done + .wizard_subscription_url.
#   7. Никаких хардкодов портов подписки (echo 8443 и т.п.).
#   8. Поведение: fresh-детект и state-хелперы (resume) работают на временных путях.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xraytailscale-wizard.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

fail() {
  echo "✗ $*" >&2
  exit 1
}

WIZARD="src/56-wizard.sh"

# Извлечь тело функции: от ^name() до следующего определения на нулевом отступе.
_fn_body() {
  local file="$1" name="$2"
  awk -v fn="^${name}\\\\(\\\\)" '
    $0 ~ fn {flag=1; print; next}
    flag && /^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{/ {exit}
    flag {print}
  ' "$file"
}

echo "Проверка мастера первичной настройки (src/56-wizard.sh)"

# ── 1. Файл и сборка ───────────────────────────────────────
[[ -f "$WIZARD" ]] || fail "$WIZARD не найден"
bash -n "$WIZARD" || fail "$WIZARD не проходит bash -n"

mod_order=$(ls src/*.sh | sed 's|src/||')
wiz_pos=$(grep -n '^56-wizard\.sh$' <<< "$mod_order" | cut -d: -f1)
menu_pos=$(grep -n '^55-main-menu\.sh$' <<< "$mod_order" | cut -d: -f1)
create_pos=$(grep -n '^60-profile-create\.sh$' <<< "$mod_order" | cut -d: -f1)
[[ -n "$wiz_pos" && -n "$menu_pos" && -n "$create_pos" ]] || fail "не найдены модули 55/56/60"
[[ "$menu_pos" -lt "$wiz_pos" && "$wiz_pos" -lt "$create_pos" ]] || \
  fail "порядок по алфавиту нарушен: 55-main-menu=$menu_pos, 56-wizard=$wiz_pos, 60-profile-create=$create_pos"
bash build.sh "$WORKDIR/xraytailscale" >/dev/null || fail "build.sh с новым модулем упал"
bash -n "$WORKDIR/xraytailscale" || fail "собранный бандл не проходит bash -n"
grep -q '^wizard_command()' "$WORKDIR/xraytailscale" || fail "wizard_command не попал в бандл"
echo "  ✓ модуль на месте (55 → 56 → 60), бандл собирается"

# Source собранного бандла: нужен для поведенческих проверок ниже
# (override email, fresh-детект, state-хелперы).
# shellcheck disable=SC1091
source "$WORKDIR/xraytailscale"

# ── 2. Публичный контракт ──────────────────────────────────
for fn in wizard_is_fresh_install run_first_run_wizard wizard_command; do
  grep -q "^${fn}()" "$WIZARD" || fail "$WIZARD: не определена ${fn}()"
done
# State-хелперы (resume) — часть контракта модуля.
for fn in _wizard_state_set _wizard_state_get _wizard_state_clear _wizard_detect_ports_note; do
  grep -q "^${fn}()" "$WIZARD" || fail "$WIZARD: не определён ${fn}()"
done
echo "  ✓ контракт: wizard_is_fresh_install / run_first_run_wizard / wizard_command + state-хелперы"

# ── 3. Порядок шага 4: self-steal раньше подписки ──────────
body=$(_fn_body "$WIZARD" run_first_run_wizard)
[[ -n "$body" ]] || fail "не удалось извлечь тело run_first_run_wizard"

ss_line=$(grep -nE '^[[:space:]]*if ! _selfsteal_provision ' <<< "$body" | head -1 | cut -d: -f1)
sub_line=$(grep -nE '^[[:space:]]*if install_subscription_ip_tls;' <<< "$body" | head -1 | cut -d: -f1)
[[ -n "$ss_line" ]] || fail "run_first_run_wizard не вызывает _selfsteal_provision"
[[ -n "$sub_line" ]] || fail "run_first_run_wizard не вызывает install_subscription_ip_tls"
[[ "$ss_line" -lt "$sub_line" ]] || \
  fail "порядок шага 4 нарушен: _selfsteal_provision (строка ${ss_line}) должен идти ДО install_subscription_ip_tls (строка ${sub_line})"
echo "  ✓ шаг 4: _selfsteal_provision (${ss_line}) → install_subscription_ip_tls (${sub_line})"

# Подписка ВСЕГДА IP-режим: доменный installer в мастере не используется.
if grep -q 'install_subscription_public_tls' <<< "$body"; then
  fail "мастер не должен вызывать install_subscription_public_tls (инвариант: подписка при self-steal = IP-режим)"
fi
echo "  ✓ подписка в мастере — только IP-режим (нет domain-mode installer'а)"

# ── 4. Email-override перед вызовом installer'а ────────────
email_line=$(grep -nE '^[[:space:]]*SUBSCRIPTION_LE_EMAIL=' <<< "$body" | head -1 | cut -d: -f1)
[[ -n "$email_line" ]] || fail "мастер не выставляет SUBSCRIPTION_LE_EMAIL перед installer'ом"
[[ "$email_line" -lt "$sub_line" ]] || \
  fail "SUBSCRIPTION_LE_EMAIL выставляется (${email_line}) ПОСЛЕ вызова installer'а (${sub_line})"
echo "  ✓ SUBSCRIPTION_LE_EMAIL (${email_line}) до installer'а (${sub_line})"

# Override в самом installer'е: непустой SUBSCRIPTION_LE_EMAIL → без read.
ip_body=$(_fn_body src/35-subscription.sh install_subscription_ip_tls)
[[ -n "$ip_body" ]] || fail "не удалось извлечь тело install_subscription_ip_tls"
grep -q 'SUBSCRIPTION_LE_EMAIL' <<< "$ip_body" || \
  fail "install_subscription_ip_tls не читает SUBSCRIPTION_LE_EMAIL (override отсутствует)"
grep -q 'read -r email' <<< "$ip_body" || \
  fail "install_subscription_ip_tls: интерактивный prompt email потерян (обратная совместимость)"
echo "  ✓ override в install_subscription_ip_tls: EMAIL из мастера, prompt сохранён"

# Поведенческая проверка override (не только текст): с валидным
# SUBSCRIPTION_LE_EMAIL и закрытым stdin исполнение обязано дойти до выбора
# порта. Если бы prompt остался, read получил бы EOF → «Некорректный email».
_override_probe() {
  (
    show_ascii() { :; }
    install_subscription_server() { return 0; }
    get_server_ip() { echo "203.0.113.10"; }
    _select_subscription_port() { return 1; }
    SUBSCRIPTION_LE_EMAIL="wizard@example.com" install_subscription_ip_tls < /dev/null 2>&1 || true
  )
}
_override_out=$(_override_probe)
grep -qF "wizard@example.com" <<< "$_override_out" || \
  fail "SUBSCRIPTION_LE_EMAIL не используется в install_subscription_ip_tls"
grep -qF "Нет свободного порта для подписки" <<< "$_override_out" || \
  fail "override не пропустил email-prompt (исполнение не дошло до выбора порта)"
if grep -qF "Некорректный email" <<< "$_override_out"; then
  fail "override игнорируется: installer прочитал пустой stdin вместо SUBSCRIPTION_LE_EMAIL"
fi
echo "  ✓ поведение: email из SUBSCRIPTION_LE_EMAIL принимается без prompt'а"

# ── 5. Профиль первого пользователя ────────────────────────
grep -q 'create_profile_all_routes "\$user_name" "no_pause"' <<< "$body" || \
  fail "мастер должен создавать профиль через create_profile_all_routes \"\$name\" \"no_pause\""
grep -qF '"$user_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$' "$WIZARD" || \
  fail "нет валидации имени пользователя ^[a-zA-Z0-9][a-zA-Z0-9_-]*$"
grep -qF '"$PROFILES_DIR/${user_name}.json"' "$WIZARD" || \
  fail "нет проверки занятости имени (PROFILES_DIR/<name>.json не должен существовать)"
grep -q 'create_profile_all_routes "\$user_name" "no_pause"' <<< "$body" || \
  fail "create_profile_all_routes вызывается не из тела run_first_run_wizard"
grep -q 'USER_NAME' <<< "$body" || fail "имя пользователя не сохраняется в state (resume)"
echo "  ✓ первый пользователь: create_profile_all_routes + no_pause + валидация имени"

# ── 6. Маркеры завершения ──────────────────────────────────
grep -qE '^WIZARD_DONE_FILE=.*/\.wizard_done' "$WIZARD" || \
  fail "маркер .wizard_done не задан"
grep -qE '^WIZARD_URL_FILE=.*/\.wizard_subscription_url' "$WIZARD" || \
  fail "файл ссылки .wizard_subscription_url не задан"
final_body=$(_fn_body "$WIZARD" _wizard_final_report)
[[ -n "$final_body" ]] || fail "нет _wizard_final_report (финальный блок шага 5)"
grep -q 'touch "\$WIZARD_DONE_FILE"' <<< "$final_body" || fail "шаг 5 не создаёт .wizard_done"
grep -q 'WIZARD_URL_FILE' <<< "$final_body" || fail "шаг 5 не пишет .wizard_subscription_url"
grep -q 'chmod 600 "\$WIZARD_URL_FILE"' <<< "$final_body" || fail ".wizard_subscription_url не получает chmod 600"
grep -q '_wizard_state_clear' <<< "$final_body" || fail "шаг 5 не очищает .wizard_state"
grep -q 'qrencode -t ANSIUTF8' <<< "$final_body" || fail "шаг 5 не показывает QR"
echo "  ✓ завершение: .wizard_done + .wizard_subscription_url (chmod 600) + state_clear + QR"

# ── 7. Нет хардкодов портов подписки ──────────────────────
if grep -qE 'echo 8443|> *[^ ]*\.subscription_port.*<<< *"?8443' "$WIZARD"; then
  fail "$WIZARD: хардкод 8443 (порт подписки должен выбираться _select_subscription_port)"
fi
grep -q '.subscription_port' "$WIZARD" || fail "мастер не читает фактический порт подписки"
echo "  ✓ без хардкодов портов, порт читается из маркера"

# ── 7b. CLI dispatch: `xraytailscale wizard` ──────────────
grep -q 'wizard)' src/99-dispatch.sh || fail "src/99-dispatch.sh: нет команды 'wizard'"
grep -q 'wizard_command' src/99-dispatch.sh || fail "src/99-dispatch.sh: 'wizard' не ведёт в wizard_command"
grep -q 'wizard_command' "$WORKDIR/xraytailscale" || fail "wizard_command не попал в бандл"
echo "  ✓ CLI: xraytailscale wizard → wizard_command (force)"

# ── 8. Поведение: fresh-детект и state (resume) ────────────
# Бандл уже sourced выше (раздел 1).
CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
WIZARD_STATE_FILE="$WORKDIR/.wizard_state"
WIZARD_DONE_FILE="$WORKDIR/.wizard_done"
WIZARD_URL_FILE="$WORKDIR/.wizard_subscription_url"
WIZARD_SUBSCRIPTION_MARKER="$WORKDIR/.subscription_installed"
mkdir -p "$PROFILES_DIR"

# (а) нет config.json → чистый сервер
rm -f "$CONFIG_FILE" "$WIZARD_DONE_FILE" "$WIZARD_SUBSCRIPTION_MARKER"
wizard_is_fresh_install || fail "fresh: отсутствие config.json должно давать fresh-install"

# (б) config с 0 inbound → чистый
echo '{"inbounds":[]}' > "$CONFIG_FILE"
wizard_is_fresh_install || fail "fresh: 0 inbound'ов должно давать fresh-install"

# (в) inbound'ы есть, подписки нет → всё ещё fresh
echo '{"inbounds":[{"port":443,"protocol":"vless","settings":{"clients":[]}}]}' > "$CONFIG_FILE"
wizard_is_fresh_install || fail "fresh: без .subscription_installed должно давать fresh-install"

# (г) inbound'ы есть и подписка стоит → уже не fresh
touch "$WIZARD_SUBSCRIPTION_MARKER"
wizard_is_fresh_install && fail "fresh: настроенный сервер не должен считаться чистым"

# (д) маркер .wizard_done → не fresh (даже если конфиг пуст)
echo '{"inbounds":[]}' > "$CONFIG_FILE"
touch "$WIZARD_DONE_FILE"
wizard_is_fresh_install && fail "fresh: .wizard_done должен отключать детект"
rm -f "$WIZARD_DONE_FILE" "$WIZARD_SUBSCRIPTION_MARKER"

# (е) state: set/get/overwrite/clear
rm -f "$WIZARD_STATE_FILE"
_wizard_state_set STEP 2 || fail "_wizard_state_set не записал STEP"
_wizard_state_set MODE domain || fail "_wizard_state_set не записал MODE"
_wizard_state_set DOMAIN example.com || fail "_wizard_state_set не записал DOMAIN"
[[ "$(_wizard_state_get STEP)" == "2" ]] || fail "_wizard_state_get STEP != 2"
[[ "$(_wizard_state_get MODE)" == "domain" ]] || fail "_wizard_state_get MODE != domain"
[[ "$(_wizard_state_get DOMAIN)" == "example.com" ]] || fail "_wizard_state_get DOMAIN != example.com"
_wizard_state_set STEP 3 || fail "_wizard_state_set не перезаписал STEP"
[[ "$(_wizard_state_get STEP)" == "3" ]] || fail "перезапись STEP не сработала"
[[ $(grep -c '^STEP=' "$WIZARD_STATE_FILE") -eq 1 ]] || fail "STEP задублирован в .wizard_state"
_wizard_state_get NOPE && fail "_wizard_state_get должен возвращать 1 для отсутствующего ключа"
_wizard_state_clear
[[ ! -f "$WIZARD_STATE_FILE" ]] || fail "_wizard_state_clear не удалил .wizard_state"
echo "  ✓ fresh-детект и state (set/get/overwrite/clear) работают"

# ── 9. Подписка переиспользует профиль user-001, а не создаёт 'happ' ──
# Симулируем состояние после шага 3 (7 маршрутов user-001) и после шага 4
# в режиме домена (self-steal сконвертировал один inbound в :443).
# _happ_ensure_default_multiroute_profile (вызывается из
# install_subscription_ip_tls) обязан взять существующий профиль.
CFG2="$WORKDIR/config2.json"
PROF2="$WORKDIR/profiles2"
mkdir -p "$PROF2"
UUID="11111111-2222-3333-4444-555555555555"

_mk_inbound() {
  local port="$1" network="$2" flow="$3" sni="$4" path="$5" grpc="$6"
  jq -n --argjson p "$port" --arg net "$network" --arg flow "$flow" \
        --arg sni "$sni" --arg path "$path" --arg grpc "$grpc" --arg uuid "$UUID" '{
      port: $p, protocol: "vless",
      settings: {clients: [{id: $uuid, flow: $flow}], decryption: "none"},
      streamSettings: ({network: $net, security: "reality",
        realitySettings: {serverNames: [$sni]}}
        + (if $path != "" then {xhttpSettings: {path: $path, host: $sni}} else {} end)
        + (if $grpc != "" then {grpcSettings: {serviceName: $grpc}} else {} end))
    }'
}

{
  _mk_inbound 31001 xhttp      ""                  www.ozon.ru          /p1 ""
  _mk_inbound 31002 xhttp      ""                  www.ozon.ru          /p2 ""
  _mk_inbound 31003 tcp        ""                  www.ozon.ru          ""  ""
  _mk_inbound 31004 grpc       ""                  www.cloudflare.com   ""  svc
  _mk_inbound 31005 tcp        "xtls-rprx-vision"  www.ozon.ru          ""  ""
  _mk_inbound 31006 tcp        "xtls-rprx-vision"  www.ozon.ru          ""  ""
  _mk_inbound 31007 tcp        "xtls-rprx-vision"  api-maps.yandex.ru   ""  ""
} | jq -s '{inbounds: .}' > "$CFG2"

jq -n --arg uuid "$UUID" '{
  name: "user-001", uuid: $uuid, schema_version: 3, multi_route: true,
  primary_route: "xhttp-legacy", sub_token: "0123456789abcdef0123456789abcdef",
  routes: [
    {label: "xhttp-legacy",     transport: "xhttp",    port: 31001, sni: "www.ozon.ru",        xhttp_path: "/p1"},
    {label: "xhttp-pq",         transport: "xhttp",    port: 31002, sni: "www.ozon.ru",        xhttp_path: "/p2", pq_enabled: true},
    {label: "tcp-mux",          transport: "tcp-mux",  port: 31003, sni: "www.ozon.ru"},
    {label: "grpc",             transport: "grpc",     port: 31004, sni: "www.cloudflare.com", grpc_service_name: "svc"},
    {label: "tcp-vision",       transport: "tcp",      port: 31005, sni: "www.ozon.ru"},
    {label: "tcp-utls-firefox", transport: "tcp-utls", port: 31006, sni: "www.ozon.ru"},
    {label: "tcp-xudp",         transport: "tcp-xudp", port: 31007, sni: "api-maps.yandex.ru"}
  ],
  transport: "xhttp", port: 31001, fingerprint: "firefox", sni: "www.ozon.ru"
}' > "$PROF2/user-001.json"

SAVED_CONFIG_FILE="$CONFIG_FILE"
SAVED_PROFILES_DIR="$PROFILES_DIR"
CONFIG_FILE="$CFG2"
PROFILES_DIR="$PROF2"

live_before=$(_profile_live_route_count "$PROF2/user-001.json")
[[ "$live_before" == "7" ]] || fail "фикстура: ожидалось 7 live-маршрутов у user-001, получено $live_before"

# Шаг 4 (domain): self-steal конвертирует порт с максимальным числом клиентов.
XRAY_BACKUPS_DIR="$WORKDIR/backups"
SELFSTEAL_PORT_FILE="$WORKDIR/.selfsteal_backend_port"
mkdir -p "$XRAY_BACKUPS_DIR"
backup_config() { local n="$1" out="${2:-}"; cp "$CONFIG_FILE" "$XRAY_BACKUPS_DIR/${n}.json"; [[ -n "$out" ]] && printf -v "$out" '%s' "$XRAY_BACKUPS_DIR/${n}.json"; return 0; }
safe_restart_xray() { return 0; }
_restore_config_backup() { return 0; }
open_firewall_port() { return 0; }
close_firewall_port() { return 0; }
fix_xray_permissions() { return 0; }

convert_port=$(_selfsteal_pick_convert_port)
_selfsteal_convert_inbound "$convert_port" "northphoto-archive.org" "127.0.0.1:8443" >/dev/null 2>&1 || \
  fail "симуляция self-steal конвертации упала"
[[ "$(jq -r '.inbounds[] | select(.port == 443) | .streamSettings.realitySettings.dest' "$CONFIG_FILE")" == "127.0.0.1:8443" ]] || \
  fail "после конвертации нет inbound :443 с dest 127.0.0.1:<backend>"

live_after=$(_profile_live_route_count "$PROF2/user-001.json")
[[ "$live_after" == "7" ]] || \
  fail "после конвертации у user-001 осталось ${live_after}/7 live-маршрутов (иначе подписка создаст лишний 'happ')"

HAPP_DEFAULT_PROFILE=""
_happ_ensure_default_multiroute_profile >/dev/null 2>&1 || \
  fail "_happ_ensure_default_multiroute_profile упал на профиле мастера"
[[ "$HAPP_DEFAULT_PROFILE" == "user-001" ]] || \
  fail "подписка не переиспользовала user-001 (HAPP_DEFAULT_PROFILE='${HAPP_DEFAULT_PROFILE}')"
[[ ! -f "$PROF2/happ.json" ]] || fail "подписка создала лишний профиль happ.json"
[[ "$(ls "$PROF2" | wc -l | tr -d ' ')" == "1" ]] || fail "в PROFILES_DIR появились лишние профили: $(ls "$PROF2")"
echo "  ✓ подписка переиспользует user-001 после self-steal, happ.json не создаётся"

CONFIG_FILE="$SAVED_CONFIG_FILE"
PROFILES_DIR="$SAVED_PROFILES_DIR"

echo "✓ wizard static checks passed"
