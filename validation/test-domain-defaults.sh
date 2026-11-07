#!/bin/bash
# test-domain-defaults.sh — серверный домен: валидация, хранение, автоподстановка
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR=$(mktemp -d /tmp/xraytailscale-domain.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

SERVER_DOMAIN_FILE="$WORKDIR/.server_domain"

# Пустое хранилище
[[ -z "$(get_server_domain)" ]] || fail "ожидался пустой домен при отсутствии файла"

# Валидация
validate_server_domain "northphoto-archive.org" || fail "валидный FQDN отклонён"
validate_server_domain "a-b.c-d.co.uk" || fail "валидный многоуровневый FQDN отклонён"
! validate_server_domain "" || fail "пустая строка принята"
! validate_server_domain "192.168.1.1" || fail "IPv4 принят за домен"
! validate_server_domain "https://example.org" || fail "URL со схемой принят"
! validate_server_domain "example.org:443" || fail "домен с портом принят"
! validate_server_domain "-bad.org" || fail "метка с ведущим дефисом принята"
! validate_server_domain "bad-.org" || fail "метка с замыкающим дефисом принята"
! validate_server_domain "nodots" || fail "одноуровневое имя принято"
! validate_server_domain "example.123" || fail "цифровой TLD принят"

# Roundtrip set/get
set_server_domain "northphoto-archive.org" || fail "set_server_domain не удался"
[[ "$(get_server_domain)" == "northphoto-archive.org" ]] || fail "roundtrip не совпал"
[[ -f "$SERVER_DOMAIN_FILE" ]] || fail "файл домена не создан"
! set_server_domain "not a domain" || fail "невалидный домен записан"

# Prompt: пустой ввод подставляет сохранённый домен (stdout = только домен)
out=$(printf '\n' | prompt_server_domain) || fail "prompt с дефолтом не удался"
[[ "$out" == "northphoto-archive.org" ]] || fail "prompt не подставил сохранённый домен: '$out'"

# Prompt: новый ввод перезаписывает сохранённый
out=$(printf 'example.com\n' | prompt_server_domain) || fail "prompt с новым доменом не удался"
[[ "$out" == "example.com" ]] || fail "prompt вернул не новый домен: '$out'"
[[ "$(get_server_domain)" == "example.com" ]] || fail "новый домен не сохранён"

# Prompt: невалидный ввод = ошибка
! printf 'bad_domain\n' | prompt_server_domain >/dev/null 2>&1 || fail "невалидный ввод prompt принят"

# Интеграция: HAPP public TLS использует автоподстановку домена
grep -q 'saved_domain=$(get_server_domain)' "$REPO_ROOT/src/35-subscription.sh" || \
  fail "подписка не использует автоподстановку домена"

echo "PASS: domain defaults (validate/set/get/prompt/subscription autofill)"
