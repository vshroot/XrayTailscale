_bypass_add_single_domain() {
  echo -n -e "${YELLOW}Введите домен (без domain:, например steamcontent.com): ${NC}"
  local user_dom
  read -r user_dom
  user_dom="${user_dom#domain:}"

  if [[ ! "$user_dom" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
    echo -e "${RED}✗ Некорректный домен${NC}"
    sleep 2
    return
  fi

  echo -n -e "${YELLOW}Добавить domain:${user_dom} в обход VPN? [y/N]: ${NC}"
  local confirm
  read -r confirm
  [[ "$confirm" =~ ^[yYдД]$ ]] || { echo -e "${CYAN}✓ Отменено${NC}"; sleep 1; return; }

  if _apply_bypass_rule "[\"domain:${user_dom}\"]"; then
    echo -e "${GREEN}✓ domain:${user_dom} добавлен в обход VPN${NC}"
  else
    echo -e "${RED}✗ Правило не применено${NC}"
  fi
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
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
    echo -e "${BLUE}    ДЕФОЛТНЫЙ BYPASS BUNDLE                   ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Выберите группы для применения:${NC}"
    echo -e "${CYAN}↑/↓ — выбор, Space — вкл/выкл, Enter — применить, q/Esc — отмена${NC}"
    echo ""

    local i
    for i in "${!group_ids[@]}"; do
      local mark="[ ]"
      [[ "${state[$i]}" == "on" ]] && mark="[x]"
      local count
      count=$(awk -F',' '{print NF}' <<< "${group_domains[$i]}")
      local pointer=" "
      [[ $i -eq $cursor ]] && pointer=">"
      echo -e "${CYAN}${pointer} $((i+1)))${NC} $mark ${group_names[$i]} (${count} доменов)"
    done

    echo ""
    echo -n -e "${YELLOW}Клавиша: ${NC}"
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
          echo -e "${YELLOW}Нет выбранных групп. Отменено.${NC}"
          sleep 1
          return
        fi

        local doms_json
        doms_json=$(printf '%s' "$all_doms_csv" | tr ',' '\n' | sed '/^$/d' | jq -R '"domain:" + .' | jq -s '.')
        local domain_count
        domain_count=$(printf '%s' "$doms_json" | jq 'length')
        echo -e "${CYAN}Применяю ${domain_count} доменов...${NC}"

        if _apply_bypass_rule "$doms_json"; then
          echo -e "${GREEN}✓ Дефолтный bundle применен${NC}"
        else
          echo -e "${RED}✗ Bundle не применен. Если был создан бэкап, config.json откатан safe_restart_xray.${NC}"
        fi
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
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
    echo -e "${YELLOW}Нет правил для удаления${NC}"
    sleep 1
    return
  fi

  echo -e "${CYAN}Текущие bypass-домены:${NC}"
  local i
  for i in "${!current_domains[@]}"; do
    echo -e "${CYAN} $((i+1)))${NC} ${current_domains[$i]}"
  done
  echo -e "${CYAN} 0)${NC} Отмена"
  echo ""
  echo -n -e "${YELLOW}Выберите правило для удаления: ${NC}"
  local choice
  read -r choice
  [[ "$choice" == "0" ]] && return
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#current_domains[@]} ]]; then
    echo -e "${RED}Неверный выбор${NC}"
    sleep 1
    return
  fi

  local selected="${current_domains[$((choice-1))]}"
  local dom="${selected#domain:}"
  echo -n -e "${YELLOW}Удалить ${selected}? [y/N]: ${NC}"
  local confirm
  read -r confirm
  [[ "$confirm" =~ ^[yYдД]$ ]] || { echo -e "${CYAN}✓ Отменено${NC}"; sleep 1; return; }

  if _bypass_remove_rule "$dom"; then
    echo -e "${GREEN}✓ ${selected} удален из обхода${NC}"
  else
    echo -e "${RED}✗ Не удалось удалить ${selected}${NC}"
  fi
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read -r _
}

_bypass_reset_all_interactive() {
  echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  СБРОС ВСЕХ BYPASS-ПРАВИЛ                                ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Будут удалены только domain bypass-правила.${NC}"
  echo -e "${CYAN}Дефолтные правила install.sh (ads, QUIC block, direct catch-all) останутся.${NC}"
  echo ""
  echo -n -e "${RED}Действительно сбросить? [y/N]: ${NC}"
  local confirm
  read -r confirm
  [[ "$confirm" =~ ^[yYдД]$ ]] || { echo -e "${CYAN}✓ Отменено${NC}"; sleep 1; return; }

  if _bypass_reset_all; then
    echo -e "${GREEN}✓ Все bypass-правила удалены${NC}"
  else
    echo -e "${RED}✗ Сброс не выполнен${NC}"
  fi
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read -r _
}

bypass_routing_menu() {
  while true; do
    show_ascii
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    УПРАВЛЕНИЕ ОБХОДОМ VPN                    ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""

    local current
    current=$(_bypass_list_current)
    if [[ -z "$current" ]]; then
      echo -e "${YELLOW}  Нет правил обхода (весь трафик через VPN)${NC}"
    else
      echo -e "${CYAN}Текущие домены в обходе:${NC}"
      while IFS= read -r dom; do
        [[ -n "$dom" ]] && echo -e "  ${GREEN}->${NC} $dom"
      done <<< "$current"
    fi
    echo ""

    echo -e "${CYAN} 1)${NC} Добавить домен в обход"
    echo -e "${CYAN} 2)${NC} Применить дефолтный bundle (5 групп)"
    echo -e "${CYAN} 3)${NC} Удалить домен из обхода"
    echo -e "${CYAN} 4)${NC} Сбросить ВСЕ правила обхода"
    echo -e "${CYAN} 0)${NC} Назад в главное меню"
    echo ""
    echo -n -e "${YELLOW}Выбор: ${NC}"

    local c
    read -r c
    case "$c" in
      1) _bypass_add_single_domain ;;
      2) _bypass_apply_bundle ;;
      3) _bypass_remove_domain_interactive ;;
      4) _bypass_reset_all_interactive ;;
      0) return ;;
      *) echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
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
