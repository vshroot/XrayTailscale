#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "Проверка Tailscale exit-node invariants"

bash -n xraytailscale update.sh install.sh uninstall.sh || fail "bash -n failed"
echo "  ✓ shell syntax ok"

grep -q '^TAILSCALE_SYSCTL_FILE=' xraytailscale || fail "missing Tailscale sysctl path constant"
grep -q '^install_tailscale_package()' xraytailscale || fail "missing Tailscale package installer"
grep -q 'https://tailscale.com/install.sh' xraytailscale || fail "Tailscale installer must use official install script"
grep -q '^enable_tailscale_ip_forwarding()' xraytailscale || fail "missing Tailscale IP forwarding setup"
grep -q 'net.ipv4.ip_forward = 1' xraytailscale || fail "exit node must enable IPv4 forwarding"
grep -q 'net.ipv6.conf.all.forwarding = 1' xraytailscale || fail "exit node must enable IPv6 forwarding"
echo "  ✓ install and forwarding setup ok"

grep -q '^configure_tailscale_exit_node()' xraytailscale || fail "missing exit-node configuration function"
grep -q -- '--advertise-exit-node' xraytailscale || fail "Tailscale must advertise exit node"
grep -q 'tailscale set --advertise-exit-node' xraytailscale || fail "existing Tailscale node must be able to advertise exit node"
grep -q '^tailscale_exit_node_menu()' xraytailscale || fail "missing Tailscale exit-node menu"
grep -q '12) tailscale_exit_node_menu' xraytailscale || fail "main menu must route option 12 to Tailscale menu"
echo "  ✓ exit-node menu path ok"

! grep -qi 'tailscale_auth_key' xraytailscale || fail "auth key must not be persisted under a named auth-key file/variable"
grep -q 'read -r -s auth_key' xraytailscale || fail "auth key prompt must be hidden"
grep -q 'auth_key=""' xraytailscale || fail "auth key variable must be cleared after use"
echo "  ✓ auth key handling ok"

grep -q 'Tailscale exit node' README.md || fail "README must document Tailscale exit node"

echo "✓ Tailscale exit-node static checks passed"
