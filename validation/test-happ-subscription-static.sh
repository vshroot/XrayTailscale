#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "Проверка HAPP subscription/install/update invariants"

bash -n xrayebator update.sh install.sh uninstall.sh || fail "bash -n failed"
echo "  ✓ shell syntax ok"

SUBHTTP_TMP=$(mktemp /tmp/xrayebator-subhttp-static.XXXXXX)
trap 'rm -f "$SUBHTTP_TMP"' EXIT
awk '/cat > \/usr\/local\/bin\/subhttp\.sh << '\''SUBHTTP_EOF'\''/{flag=1; next} /^SUBHTTP_EOF$/{flag=0} flag' \
  xrayebator > "$SUBHTTP_TMP"
[[ -s "$SUBHTTP_TMP" ]] || fail "subhttp heredoc not found"
bash -n "$SUBHTTP_TMP" || fail "generated subhttp heredoc is not valid bash"
echo "  ✓ generated subhttp syntax ok"

grep -q '^emit_500()' "$SUBHTTP_TMP" || fail "subhttp must emit HTTP 500 instead of closing connection"
! grep -q '^set -u$' "$SUBHTTP_TMP" || fail "subhttp must not use set -u; it can turn config/env issues into nginx 502"
grep -q 'source /usr/local/bin/xrayebator' "$SUBHTTP_TMP" || fail "subhttp must source installed xrayebator"
echo "  ✓ subhttp failure mode guards ok"

grep -q '^ensure_xray_runtime_user()' xrayebator || fail "xrayebator missing runtime user repair"
grep -q '^ensure_xray_runtime_user()' update.sh || fail "update.sh missing runtime user repair"
grep -q 'getent passwd xray' install.sh || fail "install.sh must verify xray user creation"
echo "  ✓ xray runtime user repair ok"

grep -q '^_subscription_restart_service()' xrayebator || fail "missing centralized subscription restart helper"
! grep -q 'enable --now xrayebator-sub.service' xrayebator || fail "xrayebator must restart/reset subscription service, not just enable --now"
grep -q '_subscription_restart_service' update.sh || fail "update.sh must use subscription restart helper after regenerating handler"
echo "  ✓ systemd restart path ok"

grep -q 'openssl' install.sh || fail "install.sh dependencies must include openssl"
grep -q 'socat' install.sh || fail "install.sh dependencies must include socat"
grep -q 'bash -n "$XRAYEBATOR_TMP"' install.sh || fail "install.sh must validate downloaded xrayebator"
grep -q 'chmod 755 "$XRAYEBATOR_TMP"' install.sh || fail "install.sh must install xrayebator as world-readable 755"
grep -q 'chmod 755 "$XRAY_TMP"' update.sh || fail "update.sh must install xrayebator as world-readable 755"
grep -q 'chmod 755 /usr/local/bin/xrayebator' update.sh || fail "update.sh must repair existing xrayebator permissions"
grep -q 'chmod 755 /usr/local/bin/xrayebator' xrayebator || fail "install_subscription_server must repair xrayebator permissions for xray user"
echo "  ✓ install dependencies/download validation ok"

grep -q 'type=xhttp&path=.*&host=.*&mode=auto' xrayebator || fail "raw XHTTP VLESS URLs must include mode=auto"
grep -q 'type=grpc&serviceName=.*&mode=gun' xrayebator || fail "raw gRPC VLESS URLs must include mode=gun"
grep -q 'tcp_vision=()' "$SUBHTTP_TMP" || fail "HAPP subscription must bucket routes for stable ordering"
grep -q 'xhttp_legacy=()' "$SUBHTTP_TMP" || fail "HAPP subscription must keep XHTTP legacy as fallback route"
grep -q 'subscription_vless_urls=$(printf.*prepare_happ_vless_urls)' "$SUBHTTP_TMP" || fail "all subscription formats must use normalized route ordering/filtering"
grep -q 'printf '\''%s'\'' "$subscription_vless_urls" | base64 -w0' "$SUBHTTP_TMP" || fail "v2ray-compatible base64 body must not use raw unfiltered route list"
grep -Fq "printf '%s\\n' \"\$subscription_vless_urls\"" "$SUBHTTP_TMP" || fail "HAPP text subscription must newline-terminate route list before optional routing URI"
! grep -q 'printf '\''%s'\'' "$vless_urls" | base64 -w0' "$SUBHTTP_TMP" || fail "v2ray-compatible base64 body must avoid raw PQ XHTTP when legacy XHTTP exists"
grep -q 'xhttp_xmux_throughput_2026' xrayebator || fail "missing XHTTP throughput migration for existing inbounds"
grep -q '"maxConcurrency": "16-32"' xrayebator || fail "new XHTTP inbounds must use throughput-friendly XMUX concurrency"
! grep -q '"maxConcurrency": "1-1"' xrayebator || fail "XHTTP XMUX maxConcurrency=1-1 must not be the shipped default"
echo "  ✓ transport URL compatibility ok"

echo "✓ HAPP subscription static checks passed"
