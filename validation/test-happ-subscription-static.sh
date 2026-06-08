#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "Проверка HAPP subscription/install/update invariants"

bash -n xraytailscale update.sh install.sh uninstall.sh || fail "bash -n failed"
echo "  ✓ shell syntax ok"

SUBHTTP_TMP=$(mktemp /tmp/xraytailscale-subhttp-static.XXXXXX)
trap 'rm -f "$SUBHTTP_TMP"' EXIT
awk '/cat > \/usr\/local\/bin\/subhttp\.sh << '\''SUBHTTP_EOF'\''/{flag=1; next} /^SUBHTTP_EOF$/{flag=0} flag' \
  xraytailscale > "$SUBHTTP_TMP"
[[ -s "$SUBHTTP_TMP" ]] || fail "subhttp heredoc not found"
bash -n "$SUBHTTP_TMP" || fail "generated subhttp heredoc is not valid bash"
echo "  ✓ generated subhttp syntax ok"

grep -q '^emit_500()' "$SUBHTTP_TMP" || fail "subhttp must emit HTTP 500 instead of closing connection"
! grep -q '^set -u$' "$SUBHTTP_TMP" || fail "subhttp must not use set -u; it can turn config/env issues into nginx 502"
grep -q 'source /usr/local/bin/xraytailscale' "$SUBHTTP_TMP" || fail "subhttp must source installed xraytailscale"
echo "  ✓ subhttp failure mode guards ok"

grep -q '^ensure_xray_runtime_user()' xraytailscale || fail "xraytailscale missing runtime user repair"
grep -q '^ensure_xray_runtime_user()' update.sh || fail "update.sh missing runtime user repair"
grep -q 'getent passwd xray' install.sh || fail "install.sh must verify xray user creation"
echo "  ✓ xray runtime user repair ok"

grep -q '^_subscription_restart_service()' xraytailscale || fail "missing centralized subscription restart helper"
! grep -q 'enable --now xraytailscale-sub.service' xraytailscale || fail "xraytailscale must restart/reset subscription service, not just enable --now"
grep -q '_subscription_restart_service' update.sh || fail "update.sh must use subscription restart helper after regenerating handler"
echo "  ✓ systemd restart path ok"

grep -q 'openssl' install.sh || fail "install.sh dependencies must include openssl"
grep -q 'socat' install.sh || fail "install.sh dependencies must include socat"
grep -q 'bash -n "$XRAYTAILSCALE_TMP"' install.sh || fail "install.sh must validate downloaded xraytailscale"
grep -q 'chmod 755 "$XRAYTAILSCALE_TMP"' install.sh || fail "install.sh must install xraytailscale as world-readable 755"
grep -q 'chmod 755 "$XRAY_TMP"' update.sh || fail "update.sh must install xraytailscale as world-readable 755"
grep -q 'chmod 755 /usr/local/bin/xraytailscale' update.sh || fail "update.sh must repair existing xraytailscale permissions"
grep -q 'chmod 755 /usr/local/bin/xraytailscale' xraytailscale || fail "install_subscription_server must repair xraytailscale permissions for xray user"
echo "  ✓ install dependencies/download validation ok"

grep -q 'type=xhttp&path=.*&mode=auto' xraytailscale || fail "raw XHTTP VLESS URLs must include mode=auto"
! grep -q 'type=xhttp&path=.*&host=.*&mode=auto' xraytailscale || fail "raw XHTTP VLESS URLs must not force Host header"
! grep -q '"host": "$sni"' xraytailscale || fail "XHTTP inbound templates must not force Host header"
grep -q 'xhttp_drop_host_2026' xraytailscale || fail "missing XHTTP Host check removal migration"
grep -q 'del(.host)' xraytailscale || fail "XHTTP Host check migration must delete xhttpSettings.host"
grep -q 'type=grpc&serviceName=.*&mode=gun' xraytailscale || fail "raw gRPC VLESS URLs must include mode=gun"
grep -q 'tcp_vision=()' "$SUBHTTP_TMP" || fail "HAPP subscription must bucket routes for stable ordering"
grep -q 'xhttp_legacy=()' "$SUBHTTP_TMP" || fail "HAPP subscription must keep XHTTP legacy as fallback route"
grep -q 'subscription_vless_urls=$(printf.*prepare_happ_vless_urls)' "$SUBHTTP_TMP" || fail "all subscription formats must use normalized route ordering/filtering"
grep -q 'printf '\''%s'\'' "$subscription_vless_urls" | base64 -w0' "$SUBHTTP_TMP" || fail "v2ray-compatible base64 body must not use raw unfiltered route list"
grep -Fq "printf '%s\\n' \"\$subscription_vless_urls\"" "$SUBHTTP_TMP" || fail "HAPP text subscription must newline-terminate route list before optional routing URI"
! grep -q 'printf '\''%s'\'' "$vless_urls" | base64 -w0' "$SUBHTTP_TMP" || fail "v2ray-compatible base64 body must avoid raw PQ XHTTP when legacy XHTTP exists"
grep -q 'xhttp_xmux_throughput_2026' xraytailscale || fail "missing XHTTP throughput migration for existing inbounds"
grep -q '"maxConcurrency": "16-32"' xraytailscale || fail "new XHTTP inbounds must use throughput-friendly XMUX concurrency"
! grep -q '"maxConcurrency": "1-1"' xraytailscale || fail "XHTTP XMUX maxConcurrency=1-1 must not be the shipped default"
echo "  ✓ transport URL compatibility ok"

echo "✓ HAPP subscription static checks passed"
