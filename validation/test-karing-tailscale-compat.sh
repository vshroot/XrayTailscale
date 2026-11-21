#!/usr/bin/env bash
# Проверка: предупреждение о несовместимости Xray ≥26.9.9 с sing-box/Karing
# и показ AuthURL при настройке Tailscale exit node.
set -u
cd "$(dirname "$0")/.."

fails=0
fail() { echo "✗ $1"; fails=$((fails+1)); }

# 1) _xray_ver_ge: корректное сравнение версий
sed -n '/^_xray_ver_ge()/,/^}/p' src/30-ui-update.sh > /tmp/_xt_vg.sh
source /tmp/_xt_vg.sh
_xray_ver_ge "26.11.9" "26.9.9" || fail "26.11.9 >= 26.9.9"
_xray_ver_ge "26.9.9" "26.9.9" || fail "26.9.9 >= 26.9.9"
! _xray_ver_ge "26.6.27" "26.9.9" || fail "26.6.27 < 26.9.9"
! _xray_ver_ge "25.12.8" "26.9.9" || fail "25.12.8 < 26.9.9"
_xray_ver_ge "26.10.1" "26.9.30" || fail "26.10.1 >= 26.9.30"
echo "  ✓ _xray_ver_ge"

# 2) Предупреждение срабатывает при переходе через порог и молчит в остальных случаях
RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
sed -n '/^_xray_update_karing_warning()/,/^}/p' src/30-ui-update.sh > /tmp/_xt_kw.sh
source /tmp/_xt_kw.sh
out=$(_xray_update_karing_warning "26.6.27" "26.11.9")
grep -q "Karing" <<< "$out" || fail "warning shown when crossing 26.9.9"
out=$(_xray_update_karing_warning "26.6.27" "26.7.28")
[[ -z "$out" ]] || fail "no warning below threshold"
out=$(_xray_update_karing_warning "26.11.9" "26.11.10")
[[ -z "$out" ]] || fail "no warning when already >= threshold"
echo "  ✓ _xray_update_karing_warning"

# 3) Все три копии update_xray_core вызывают предупреждение
for f in xraytailscale update.sh install.sh; do
  grep -q '_xray_update_karing_warning "$CURRENT_VERSION" "$TARGET_VERSION"' "$f" \
    || fail "$f wires the karing warning"
done
echo "  ✓ warning wired in all three copies"

# 4) Tailscale: AuthURL достаётся и печатается пользователю
grep -q 'AuthURL' src/45-tailscale.sh || fail "tailscale reads AuthURL"
grep -q 'LOG IN TO TAILSCALE' src/45-tailscale.sh || fail "tailscale prints the login URL banner"
grep -q '_tailscale_fix_udp_gro' src/45-tailscale.sh || fail "UDP GRO fix is wired"
echo "  ✓ tailscale login URL + UDP GRO"

rm -f /tmp/_xt_vg.sh /tmp/_xt_kw.sh

if [[ "$fails" -eq 0 ]]; then
  echo "PASS test-karing-tailscale-compat.sh"
else
  echo "FAIL: $fails"
  exit 1
fi
