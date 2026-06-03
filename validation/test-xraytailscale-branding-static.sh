#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "x $*" >&2
  exit 1
}

old_lower="xrayebator"
old_title="Xrayebator"
old_upper="XRAYEBATOR"

echo "Checking XrayTailscale command branding"

[[ -f xraytailscale ]] || fail "main CLI file must be xraytailscale"
[[ ! -f xrayebator ]] || fail "old xrayebator CLI file must be renamed"

grep -q 'sudo xraytailscale' README.md || fail "README must document sudo xraytailscale"
grep -q 'xraytailscale-update' README.md || fail "README must document xraytailscale-update"
grep -q 'xraytailscale-uninstall' README.md || fail "README must document xraytailscale-uninstall"
grep -Fq 'curl -fsSL https://raw.githubusercontent.com/vshroot/XrayTailscale/main/install.sh | sudo bash' README.md || fail "README must document public one-command deploy"
! grep -Eq 'GitHub token|XRAYTAILSCALE_GITHUB_TOKEN' README.md || fail "README must not require a GitHub token for deploy"

grep -q '/usr/local/bin/xraytailscale' install.sh || fail "installer must install /usr/local/bin/xraytailscale"
grep -q '/usr/local/bin/xraytailscale' update.sh || fail "updater must update /usr/local/bin/xraytailscale"
grep -q 'xraytailscale-sub.service' xraytailscale || fail "subscription service must use xraytailscale-sub.service"
grep -q 'source /usr/local/bin/xraytailscale' xraytailscale || fail "subhttp handler must source xraytailscale"

if rg -n "${old_lower}|${old_title}|${old_upper}" \
    --glob '!validation/test-xraytailscale-branding-static.sh' \
    --glob '!.git/**' .; then
  fail "old Xrayebator naming remains"
fi

echo "XrayTailscale branding checks passed"
