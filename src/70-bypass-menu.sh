_bypass_add_single_domain() {
  echo -n -e "${YELLOW}Enter a domain (without domain:, e.g. steamcontent.com): ${NC}"
  local user_dom
  read -r user_dom
  user_dom="${user_dom#domain:}"

  if [[ ! "$user_dom" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
    echo -e "${RED}✗ Invalid domain${NC}"
    sleep 2
    return
  fi

  echo -n -e "${YELLOW}Add domain:${user_dom} to the VPN bypass? [y/N]: ${NC}"
  local confirm
  read -r confirm
  [[ "$confirm" =~ ^[yYдД]$ ]] || { echo -e "${CYAN}✓ Cancelled${NC}"; sleep 1; return; }

  if _apply_bypass_rule "[\"domain:${user_dom}\"]"; then
    echo -e "${GREEN}✓ domain:${user_dom} added to the VPN bypass${NC}"
  else
    echo -e "${RED}✗ The rule was not applied${NC}"
  fi
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _
}

_bypass_apply_bundle() {
  local -a group_ids=()
  local -a group_names=()
  local -a group_domains=()
  local -a state=()
  local cursor=0
  local gid gname doms_csv

  while IFS='|' read -r gid gname doms_csv; do
    [[ -z "$gid" ]] && continue
    group_ids+=("$gid")
    group_names+=("$gname")
    group_domains+=("$doms_csv")
    state+=("on")
  done < <(_bypass_bundle_groups)

  while true; do
    show_ascii
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    DEFAULT BYPASS BUNDLE                   ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Choose the groups to apply:${NC}"
    echo -e "${CYAN}↑/↓ to move, Space to toggle, Enter to apply, q/Esc to cancel${NC}"
    echo ""

    local i
    for i in "${!group_ids[@]}"; do
      local mark="[ ]"
      [[ "${state[$i]}" == "on" ]] && mark="[x]"
      local count
      count=$(awk -F',' '{print NF}' <<< "${group_domains[$i]}")
      local pointer=" "
      [[ $i -eq $cursor ]] && pointer=">"
      echo -e "${CYAN}${pointer} $((i+1)))${NC} $mark ${group_names[$i]} (${count} domains)"
    done

    echo ""
    echo -n -e "${YELLOW}Key: ${NC}"
    local key rest
    IFS= read -rsn1 key
    case "$key" in
      "")
        local all_doms_csv=""
        for i in "${!group_ids[@]}"; do
          if [[ "${state[$i]}" == "on" ]]; then
            all_doms_csv="${all_doms_csv}${all_doms_csv:+,}${group_domains[$i]}"
          fi
        done

        if [[ -z "$all_doms_csv" ]]; then
          echo -e "${YELLOW}No groups selected. Cancelled.${NC}"
          sleep 1
          return
        fi

        local doms_json
        doms_json=$(printf '%s' "$all_doms_csv" | tr ',' '\n' | sed '/^$/d' | jq -R '"domain:" + .' | jq -s '.')
        local domain_count
        domain_count=$(printf '%s' "$doms_json" | jq 'length')
        echo -e "${CYAN}Applying ${domain_count} domains...${NC}"

        if _apply_bypass_rule "$doms_json"; then
          echo -e "${GREEN}✓ Default bundle applied${NC}"
        else
          echo -e "${RED}✗ Bundle not applied. If a backup was made, config.json was rolled back by safe_restart_xray.${NC}"
        fi
        echo -n -e "${YELLOW}Press Enter to continue...${NC}"
        read -r _
        return
        ;;
      " ")
        if [[ "${state[$cursor]}" == "on" ]]; then
          state[$cursor]="off"
        else
          state[$cursor]="on"
        fi
        ;;
      q|Q)
        return
        ;;
      $'\e')
        rest=""
        IFS= read -rsn2 -t 0.1 rest || true
        case "$rest" in
          "[A")
            ((cursor--))
            [[ $cursor -lt 0 ]] && cursor=$((${#group_ids[@]} - 1))
            ;;
          "[B")
            ((cursor++))
            [[ $cursor -ge ${#group_ids[@]} ]] && cursor=0
            ;;
          *)
            return
            ;;
        esac
        ;;
      *)
        # Fallback для терминалов без нормальных escape-последовательностей.
        if [[ "$key" =~ ^[0-9]$ ]] && [[ "$key" -ge 1 ]] && [[ "$key" -le ${#group_ids[@]} ]]; then
          local idx=$((key-1))
          cursor=$idx
          if [[ "${state[$idx]}" == "on" ]]; then
            state[$idx]="off"
          else
            state[$idx]="on"
          fi
        fi
        ;;
    esac
  done
}

_bypass_remove_domain_interactive() {
  local -a current_domains=()
  mapfile -t current_domains < <(_bypass_list_current)

  if [[ ${#current_domains[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No rules to delete${NC}"
    sleep 1
    return
  fi

  echo -e "${CYAN}Current bypass domains:${NC}"
  local i
  for i in "${!current_domains[@]}"; do
    echo -e "${CYAN} $((i+1)))${NC} ${current_domains[$i]}"
  done
  echo -e "${CYAN} 0)${NC} Cancel"
  echo ""
  echo -n -e "${YELLOW}Choose a rule to delete: ${NC}"
  local choice
  read -r choice
  [[ "$choice" == "0" ]] && return
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#current_domains[@]} ]]; then
    echo -e "${RED}Invalid choice${NC}"
    sleep 1
    return
  fi

  local selected="${current_domains[$((choice-1))]}"
  local dom="${selected#domain:}"
  echo -n -e "${YELLOW}Delete ${selected}? [y/N]: ${NC}"
  local confirm
  read -r confirm
  [[ "$confirm" =~ ^[yYдД]$ ]] || { echo -e "${CYAN}✓ Cancelled${NC}"; sleep 1; return; }

  if _bypass_remove_rule "$dom"; then
    echo -e "${GREEN}✓ ${selected} removed from the bypass${NC}"
  else
    echo -e "${RED}✗ Could not remove ${selected}${NC}"
  fi
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _
}

_bypass_reset_all_interactive() {
  echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  RESET ALL BYPASS RULES                                ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Only domain bypass rules will be removed.${NC}"
  echo -e "${CYAN}The default install.sh rules (ads, QUIC block, direct catch-all) stay.${NC}"
  echo ""
  echo -n -e "${RED}Really reset? [y/N]: ${NC}"
  local confirm
  read -r confirm
  [[ "$confirm" =~ ^[yYдД]$ ]] || { echo -e "${CYAN}✓ Cancelled${NC}"; sleep 1; return; }

  if _bypass_reset_all; then
    echo -e "${GREEN}✓ All bypass rules removed${NC}"
  else
    echo -e "${RED}✗ Reset failed${NC}"
  fi
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _
}

bypass_routing_menu() {
  while true; do
    show_ascii
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    VPN BYPASS MANAGEMENT                    ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""

    local current
    current=$(_bypass_list_current)
    if [[ -z "$current" ]]; then
      echo -e "${YELLOW}  No bypass rules (all traffic goes through the VPN)${NC}"
    else
      echo -e "${CYAN}Current domains in the bypass:${NC}"
      while IFS= read -r dom; do
        [[ -n "$dom" ]] && echo -e "  ${GREEN}->${NC} $dom"
      done <<< "$current"
    fi
    echo ""

    echo -e "${CYAN} 1)${NC} Add a domain to the bypass"
    echo -e "${CYAN} 2)${NC} Apply the default bundle (5 groups)"
    echo -e "${CYAN} 3)${NC} Remove a domain from the bypass"
    echo -e "${CYAN} 4)${NC} Reset ALL bypass rules"
    echo -e "${CYAN} 0)${NC} Back to the main menu"
    echo ""
    echo -n -e "${YELLOW}Choice: ${NC}"

    local c
    read -r c
    case "$c" in
      1) _bypass_add_single_domain ;;
      2) _bypass_apply_bundle ;;
      3) _bypass_remove_domain_interactive ;;
      4) _bypass_reset_all_interactive ;;
      0) return ;;
      *) echo -e "${RED}Invalid choice${NC}"; sleep 1 ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════
# POST-QUANTUM UPGRADE (REQ-A09 REVISED — IN-PLACE replace)
# ═══════════════════════════════════════════════════════════

# Меню in-place миграции legacy профиля на XHTTP+Reality+PQ.
# Сохраняет UUID и port исходного инбаунда; перезаписывает streamSettings + decryption.
# При shared inbound (>1 профиля на порту) — ВСЕ профили на этом порту переводятся.
# Внутренне разбит на 3 фазы (1a UI / 1b MUTATION / 1c POST-MUTATION) для checkpoint-recoverability.
