main_menu() {
  # Run migrations on first launch after upgrade.
  # Каждая миграция: marker check → backup → fn → safe_restart_xray (если fn вернула 0)
  # → touch marker. При failure любого шага — marker НЕ выставляется, миграция повторится.
  # Three-valued contract: fn returns 0=changed, 1=no-op, ≥2=fail.

  local migration_failures=0

  migrate_client_fingerprint_state_2026 || ((migration_failures++))
  run_migration "xhttp_migrated"                       "XHTTP host/SNI sync"             migrate_xhttp_profiles             || ((migration_failures++))
  run_migration "xhttp_drop_host_2026"                 "XHTTP: remove forced Host check" _migrate_xhttp_drop_host_2026      || ((migration_failures++))
  run_migration "xhttp_path_sync_2026"                 "XHTTP path sync для существующих профилей" _migrate_xhttp_path_sync_2026 || ((migration_failures++))
  run_migration "xhttp_path_sync_after_multiroute_fix_2026" "XHTTP path sync после фикса multi-route генерации" _migrate_xhttp_path_sync_2026 || ((migration_failures++))
  run_migration "xhttp_route_path_repair_2026"         "XHTTP route path repair"        _migrate_xhttp_route_path_repair_2026 || ((migration_failures++))
  run_migration "xhttp_reality_stream_one_2026"        "XHTTP Reality mode stream-one"   _migrate_xhttp_reality_stream_one_2026 || ((migration_failures++))
  run_migration "legacy_udp443_block_removed_v3"       "Remove legacy bare UDP/443 block" migrate_legacy_managed_udp443_block_v3 || ((migration_failures++))
  run_migration "routing_v132_migrated"                "Routing default direct rule"      migrate_routing_config             || ((migration_failures++))
  run_migration "xhttp_mode_migrated"                  "XHTTP mode stream→auto"           migrate_xhttp_mode                 || ((migration_failures++))
  run_migration "xhttp_extra_restored"                 "XHTTP extra anti-DPI restore"     migrate_xhttp_extra_restore        || ((migration_failures++))
  run_migration "transport_profile_metadata_migrated"  "Transport profile metadata"        migrate_transport_profile_metadata || ((migration_failures++))
  run_migration "config_optimized"                     "Config optimization (DNS/log)"     migrate_config_optimization        || ((migration_failures++))
  run_migration "xmux_explicit_2026"                   "Explicit xmux block для XHTTP"     migrate_xmux_explicit_2026         || ((migration_failures++))
  run_migration "xhttp_xmux_throughput_2026"           "XHTTP XMUX throughput profile"      _migrate_xhttp_xmux_throughput_2026 || ((migration_failures++))
  run_migration "mlkem_keys_generated"                 "PQ ключи VLESS Encryption (mlkem768x25519plus)" _migrate_mlkem_keys || ((migration_failures++))
  run_migration "xhttp_default_2026"                   "XHTTP+PQ как дефолтный пресет создания профиля" _migrate_xhttp_default_2026 || ((migration_failures++))
  run_migration "subscription_tokens_2026"             "Subscription tokens (Phase 7) для существующих профилей" _migrate_subscription_tokens_2026 || ((migration_failures++))
  run_migration "happ_legacy_xhttp_route_2026"         "HAPP subscription не меняет существующие профили" _migrate_happ_legacy_xhttp_route_2026 || ((migration_failures++))
  if [[ ! -f /usr/local/etc/xray/.sni_list_2026 ]]; then
    echo -e "${YELLOW}Перед SNI миграцией доступна команда probe-test для проверки доступности SNI.${NC}"
    echo -n -e "${YELLOW}Запустить probe-test сейчас? [y/N]: ${NC}"
    local probe_ans
    read -r probe_ans
    probe_ans=${probe_ans:-N}
    if [[ "$probe_ans" =~ ^[yYдД]$ ]]; then
      probe_test_command
      echo -n -e "${YELLOW}Нажмите Enter для продолжения миграции...${NC}"
      read -r _
    fi
  fi
  run_migration "sni_list_2026" "SNI list 2026 (РФ-банки/логистика, удалить apple/icloud)" _migrate_sni_list_2026 || ((migration_failures++))
  run_migration "bypass_routing_2026" "Bypass routing first-run prompt (опционально)" _migrate_bypass_routing_2026 || ((migration_failures++))
  run_migration "subhttp_multiroute_2026" "HAPP subhttp multi-route handler" _migrate_subhttp_multiroute_2026 || ((migration_failures++))
  run_migration "subhttp_client_compat_2026" "HAPP/v2rayNG subscription client compatibility" _migrate_subhttp_client_compat_2026 || ((migration_failures++))
  run_migration "subhttp_no_default_happ_routing_2026" "HAPP subscription: no default routing profile" _migrate_subhttp_no_default_happ_routing_2026 || ((migration_failures++))
  run_migration "subhttp_stale_profiles_410_2026" "HAPP subscription: stale profile diagnostics" _migrate_subhttp_stale_profiles_410_2026 || ((migration_failures++))
  run_migration "subhttp_happ_xhttp_compat_2026" "HAPP subscription: XHTTP mode/no-limit compatibility" _migrate_subhttp_happ_xhttp_compat_2026 || ((migration_failures++))
  run_migration "subhttp_happ_legacy_xhttp_2026" "HAPP subscription: prefer legacy XHTTP route" _migrate_subhttp_happ_legacy_xhttp_2026 || ((migration_failures++))

  if ! migrate_remove_legacy_tcp_tuning_v3; then
    echo -e "${YELLOW}⚠ Legacy host TCP tuning cleanup не завершён. Проверьте sysctl-конфиги вручную.${NC}"
  fi

  # Aggregate report (RESEARCH §«Error reporting»): чтобы пользователь не пропустил
  # failure среди скроллящегося TUI вывода.
  if [[ $migration_failures -gt 0 ]]; then
    echo
    echo -e "${YELLOW}⚠ $migration_failures миграций не завершились — повторятся при следующем запуске${NC}"
    echo -e "${YELLOW}  Логи бэкапов: /usr/local/etc/xray/backups/${NC}"
    read -n 1 -p "Нажмите любую клавишу для продолжения..."
    echo
  fi

  # Phase 5 nag: Xray-core отстает на 2+ minor versions (REQ-B02)
  # Запускается раз за сессию (вне while loop), не блокирует если GitHub недоступен.
  _check_xray_outdated_nag

  # Phase 6 first-run banner: показываем один раз после установки v2.0 (REQ-A10).
  # Marker: /usr/local/etc/xray/.pq_banner_shown
  show_pq_banner_once

  fix_xray_permissions

  while true; do
    show_ascii

    # Показываем текущую ветку
    local current_branch=$(cat /usr/local/etc/xray/.current_branch 2>/dev/null || echo "main")
    case $current_branch in
      main)
        echo -e "${GREEN}[Stable]${NC} Стабильная версия"
        ;;
      dev)
        echo -e "${BLUE}[Dev]${NC} Версия с быстрыми фиксами"
        ;;
      experimental)
        echo -e "${MAGENTA}[Experimental]${NC} Экспериментальная версия"
        ;;
      *)
        echo -e "${MAGENTA}[Branch]${NC} ${current_branch}"
        ;;
    esac
    echo ""

    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║            ГЛАВНОЕ МЕНЮ                ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN} 1)${NC} Создать новый профиль"
    echo -e "${CYAN} 2)${NC} Удалить существующий профиль"
    echo -e "${CYAN} 3)${NC} Подключиться по профилю"
    echo ""
    echo -e "${MAGENTA} УПРАВЛЕНИЕ ПРОФИЛЕМ:${NC}"
    echo -e "${CYAN} 4)${NC} Управление профилем (SNI / fingerprint / port / advanced)"
    echo ""
    echo -e "${MAGENTA} POST-QUANTUM ENCRYPTION:${NC}"
    echo -e "${CYAN} 8)${NC} Обновить профиль до post-quantum (PQ XHTTP+Reality)"
    echo ""
    echo -e "${MAGENTA} HAPP SUBSCRIPTION:${NC}"
    echo -e "${CYAN} 9)${NC} Подписка HAPP (авто 7 маршрутов + URL/QR)"
    echo -e "${CYAN}10)${NC} Bulk HAPP users (multi-route URLs)"
    echo ""
    echo -e "${MAGENTA} ОБНОВЛЕНИЕ:${NC}"
    echo -e "${CYAN}11)${NC} Обновить Xray-core"
    echo ""
    echo -e "${MAGENTA} BYPASS ROUTING:${NC}"
    echo -e "${CYAN}12)${NC} Управление обходом VPN"
    echo ""
    echo -e "${MAGENTA} TAILSCALE:${NC}"
    echo -e "${CYAN}13)${NC} Tailscale exit node"
    echo ""
    echo -e "${MAGENTA} CASCADE:${NC}"
    echo -e "${CYAN}14)${NC} Каскад / upstream-ноды"
    echo -e "${CYAN}15)${NC} Поднять outbound-сервер (зарубежная нода)"
    echo ""
    echo -e "${MAGENTA} SELF-STEAL (свой сайт):${NC}"
    echo -e "${CYAN}16)${NC} Self-steal: VLESS+Reality+Vision :443 под свой домен"
    echo ""
    echo -e "${RED} 0)${NC} Выход"
    echo ""
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo -n -e "${YELLOW}Выберите действие: ${NC}"
    read choice
    case $choice in
      1) create_profile_menu ;;
      2) delete_profile_menu ;;
      3) connect_profile_menu ;;
      4) manage_profile_menu ;;
      8) upgrade_profile_to_pq_menu ;;
      9) happ_subscription_menu ;;
      10) bulk_happ_users_menu ;;
      11) update_command ;;
      12) bypass_routing_menu ;;
      13) tailscale_exit_node_menu ;;
      14) cascade_mode_menu ;;
      15) setup_outbound_server_menu ;;
      16) selfsteal_menu ;;
      0) exit 0 ;;
      *) echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
    esac
  done
}

# Меню создания профиля
