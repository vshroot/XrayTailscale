#!/bin/bash
# test-build-sync.sh — собранный xraytailscale должен точно соответствовать src/*.sh
# Ловит ситуацию «отредактировали модуль и забыли пересобрать» (и наоборот).
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xraytailscale-build-sync.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -d src ] || fail "src/ не найден"
bash build.sh "$WORKDIR/xraytailscale" >/dev/null || fail "build.sh завершился с ошибкой"
cmp -s "$WORKDIR/xraytailscale" xraytailscale || \
  fail "src/*.sh и xraytailscale рассинхронизированы. Запустите: ./build.sh"
bash -n xraytailscale || fail "собранный файл не проходит bash -n"

echo "PASS: build sync (src/*.sh == xraytailscale)"
