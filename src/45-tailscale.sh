_tailscale_default_hostname() {
  local raw
  raw=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "vps")
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//; s/-$//; s/--*/-/g')
  [[ -z "$raw" ]] && raw="vps"
  printf 'xraytailscale-%s\n' "$raw"
}

install_tailscale_package() {
  echo -e "${CYAN}  → Checking Tailscale...${NC}"

  if ! command -v tailscale >/dev/null 2>&1; then
    local installer_tmp
    installer_tmp=$(mktemp /tmp/tailscale-install.XXXXXX) || {
      echo -e "${RED}✗ mktemp failed for the Tailscale installer${NC}"
      return 1
    }

    echo -e "${CYAN}  → Downloading the official Tailscale installer...${NC}"
    if ! curl -fsSL --connect-timeout 10 --max-time 120 \
        https://tailscale.com/install.sh -o "$installer_tmp"; then
      rm -f "$installer_tmp"
      echo -e "${RED}✗ Could not download https://tailscale.com/install.sh${NC}"
      return 1
    fi

    if ! sh "$installer_tmp"; then
      rm -f "$installer_tmp"
      echo -e "${RED}✗ The Tailscale installer failed${NC}"
      return 1
    fi
    rm -f "$installer_tmp"
  fi

  if ! command -v tailscale >/dev/null 2>&1; then
    echo -e "${RED}✗ tailscale CLI not found after install${NC}"
    return 1
  fi

  if ! systemctl enable --now tailscaled >/dev/null 2>&1; then
    echo -e "${RED}✗ Could not start tailscaled.service${NC}"
    echo -e "${YELLOW}  Check: systemctl status tailscaled --no-pager -l${NC}"
    return 1
  fi

  echo -e "${GREEN}  ✓ Tailscale installed, tailscaled started${NC}"
  return 0
}

enable_tailscale_ip_forwarding() {
  echo -e "${CYAN}  → Enabling IP forwarding for the Tailscale exit node...${NC}"

  mkdir -p "$(dirname "$TAILSCALE_SYSCTL_FILE")"
  cat > "$TAILSCALE_SYSCTL_FILE" << 'TAILSCALE_SYSCTL_EOF'
# XrayTailscale Tailscale exit node forwarding.
# Required for tailscale set --advertise-exit-node.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
TAILSCALE_SYSCTL_EOF

  chmod 644 "$TAILSCALE_SYSCTL_FILE"
  if ! sysctl -p "$TAILSCALE_SYSCTL_FILE" >/dev/null 2>&1; then
    echo -e "${RED}✗ sysctl did not apply $TAILSCALE_SYSCTL_FILE${NC}"
    return 1
  fi

  echo -e "${GREEN}  ✓ IP forwarding enabled${NC}"

  # Tailscale рекомендует UDP GRO forwarding для throughput exit node.
  # Best-effort: не валим настройку, если ethtool нет или NIC не поддерживает.
  _tailscale_fix_udp_gro || true
  return 0
}

_tailscale_fix_udp_gro() {
  command -v ethtool >/dev/null 2>&1 || return 0
  local wan_if
  wan_if=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [[ -n "$wan_if" ]] || return 0
  # Уже включено?
  if ethtool -k "$wan_if" 2>/dev/null | grep -q 'rx-udp-gro-forwarding: on'; then
    return 0
  fi
  if ethtool -K "$wan_if" rx-udp-gro-forwarding on rx-gro-list off >/dev/null 2>&1; then
    echo -e "${GREEN}  ✓ UDP GRO forwarding enabled on ${wan_if}${NC}"
    # Persist через systemd unit, чтобы переживало reboot.
    cat > /etc/systemd/system/tailscale-udp-gro.service <<GRO_EOF
[Unit]
Description=Tailscale UDP GRO forwarding on ${wan_if}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'ethtool -K ${wan_if} rx-udp-gro-forwarding on rx-gro-list off || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
GRO_EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable tailscale-udp-gro.service >/dev/null 2>&1 || true
  fi
  return 0
}

configure_tailscale_exit_node() {
  install_tailscale_package || return 1
  enable_tailscale_ip_forwarding || return 1

  local backend_state
  backend_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // ""' 2>/dev/null || true)

  if [[ "$backend_state" == "Running" ]]; then
    echo -e "${CYAN}  → Tailscale is already joined to the tailnet, enabling exit-node advertising...${NC}"
    if ! tailscale set --advertise-exit-node; then
      echo -e "${RED}✗ Could not run tailscale set --advertise-exit-node${NC}"
      return 1
    fi
  else
    local default_hostname node_hostname auth_key
    default_hostname=$(_tailscale_default_hostname)
    echo -n -e "${YELLOW}Hostname in the tailnet [${default_hostname}]: ${NC}"
    read -r node_hostname
    node_hostname="${node_hostname:-$default_hostname}"

    if [[ ! "$node_hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]]; then
      echo -e "${RED}✗ Invalid hostname. Use letters, digits and hyphens.${NC}"
      return 1
    fi

    echo ""
    echo -e "${CYAN}You can paste a Tailscale auth key for unattended login.${NC}"
    echo -e "${YELLOW}If you leave it empty, Tailscale will show a URL for manual login.${NC}"
    echo -n -e "${YELLOW}Auth key (hidden input, Enter=manual login): ${NC}"
    read -r -s auth_key
    echo ""

    local -a up_args=(up --advertise-exit-node --hostname "$node_hostname")
    if [[ -n "$auth_key" ]]; then
      up_args+=(--auth-key "$auth_key")
    fi

    # tailscale up БЛОКИРУЕТСЯ до логина и печатает ссылку только один раз.
    # Запускаем в фоне и явно достаём AuthURL из `tailscale status --json`,
    # чтобы пользователь гарантированно увидел ссылку (раньше она терялась).
    local up_log up_pid auth_url="" i up_rc state
    up_log=$(mktemp /tmp/tailscale-up.XXXXXX) || return 1
    tailscale "${up_args[@]}" >"$up_log" 2>&1 &
    up_pid=$!

    for i in $(seq 1 15); do
      auth_url=$(tailscale status --json 2>/dev/null | jq -r '.AuthURL // empty' 2>/dev/null || true)
      [[ -n "$auth_url" ]] && break
      kill -0 "$up_pid" 2>/dev/null || break
      sleep 1
    done

    if [[ -n "$auth_url" ]]; then
      echo ""
      echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
      echo -e "${GREEN}║  LOG IN TO TAILSCALE — open this URL in your browser:    ║${NC}"
      echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
      echo -e "${CYAN}$auth_url${NC}"
      echo ""
      echo -e "${YELLOW}After logging in, this setup continues automatically (up to 5 min).${NC}"
      for i in $(seq 1 150); do
        state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // ""' 2>/dev/null || true)
        [[ "$state" == "Running" ]] && break
        kill -0 "$up_pid" 2>/dev/null || break
        sleep 2
      done
    fi

    wait "$up_pid"; up_rc=$?
    if [[ "$up_rc" -ne 0 ]]; then
      cat "$up_log" >&2 || true
      rm -f "$up_log"
      auth_key=""
      echo -e "${RED}✗ tailscale up could not connect the exit node${NC}"
      echo -e "${YELLOW}  Retry: run this menu item again after logging in at https://login.tailscale.com${NC}"
      return 1
    fi
    rm -f "$up_log"
    auth_key=""

    printf '%s\n' "$node_hostname" > /usr/local/etc/xray/.tailscale_hostname
    chmod 644 /usr/local/etc/xray/.tailscale_hostname
    chown xray:xray /usr/local/etc/xray/.tailscale_hostname 2>/dev/null || true
  fi

  echo ""
  echo -e "${GREEN}✓ Tailscale exit node advertised${NC}"
  echo -e "${YELLOW}Important: in the Tailscale admin console allow 'Use as exit node' for this machine.${NC}"
  echo -e "${CYAN}Tailscale IPv4:${NC} $(tailscale ip -4 2>/dev/null || echo 'not available yet')"
  echo ""
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _
}

show_tailscale_status() {
  if ! command -v tailscale >/dev/null 2>&1; then
    echo -e "${YELLOW}Tailscale is not installed${NC}"
    return 0
  fi

  echo -e "${BLUE}tailscaled:${NC}"
  systemctl status tailscaled --no-pager -l 2>/dev/null | sed -n '1,8p' || true
  echo ""
  echo -e "${BLUE}tailscale status:${NC}"
  tailscale status 2>/dev/null || true
  echo ""
  echo -e "${BLUE}tailscale ip:${NC} $(tailscale ip -4 2>/dev/null || echo 'no IPv4')"
}

disable_tailscale_exit_node() {
  if ! command -v tailscale >/dev/null 2>&1; then
    echo -e "${YELLOW}Tailscale is not installed${NC}"
    sleep 1
    return 0
  fi

  echo -n -e "${YELLOW}Disable advertise-exit-node on this machine? [y/N]: ${NC}"
  local confirm
  read -r confirm
  if [[ ! "$confirm" =~ ^[yYдД]$ ]]; then
    echo -e "${CYAN}✓ Cancelled${NC}"
    sleep 1
    return 0
  fi

  if tailscale set --advertise-exit-node=false; then
    echo -e "${GREEN}✓ Exit-node advertising disabled${NC}"
  else
    echo -e "${RED}✗ Could not disable advertise-exit-node${NC}"
  fi
  sleep 2
}

tailscale_exit_node_menu() {
  while true; do
    show_ascii
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    TAILSCALE EXIT NODE                       ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""

    if command -v tailscale >/dev/null 2>&1; then
      local ts_ip
      ts_ip=$(tailscale ip -4 2>/dev/null || true)
      if [[ -n "$ts_ip" ]]; then
        echo -e "${GREEN}  ✓ Tailscale IPv4: ${ts_ip}${NC}"
      else
        echo -e "${YELLOW}  ⚠ Tailscale is installed, but the node is not joined yet${NC}"
      fi
    else
      echo -e "${YELLOW}  ⚠ Tailscale is not installed${NC}"
    fi
    echo ""

    echo -e "${CYAN} 1)${NC} Install/configure the Tailscale exit node"
    echo -e "${CYAN} 2)${NC} Show the Tailscale status"
    echo -e "${CYAN} 3)${NC} Disable advertise-exit-node"
    echo -e "${CYAN} 0)${NC} Back to the main menu"
    echo ""
    echo -n -e "${YELLOW}Choice: ${NC}"
    local choice
    read -r choice
    case "$choice" in
      1|"") configure_tailscale_exit_node ;;
      2)
        show_tailscale_status
        echo ""
        echo -n -e "${YELLOW}Press Enter to continue...${NC}"
        read -r _
        ;;
      3) disable_tailscale_exit_node ;;
      0) return ;;
      *) echo -e "${RED}Invalid choice${NC}"; sleep 1 ;;
    esac
  done
}

