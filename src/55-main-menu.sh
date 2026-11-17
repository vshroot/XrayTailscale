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

  # Одноразовое предупреждение перед необратимой сменой старых vless:// ссылок.
  # Отказ не создаёт маркер предупреждения, поэтому вопрос повторится при следующем запуске.
  local pq_migration_warned="/usr/local/etc/xray/.pq_migration_warned"
  local pq_migration_allowed=1
  local pq_migration_answered_yes=0
  if [[ ! -f "$pq_migration_warned" ]] && [[ -n "$(_list_legacy_pq_profile_names)" ]]; then
    echo -e "${YELLOW}Warning: old single-route profiles will be switched to XHTTP+PQ. Manual vless:// links stop working (subscriptions update themselves).${NC}"
    echo -n -e "${YELLOW}Continue the PQ migration? [Y/n]: ${NC}"
    local pq_migration_answer=""
    read -r pq_migration_answer || {
      echo
      echo -e "${YELLOW}Input ended without an answer — the PQ migration is skipped until the next run${NC}"
      pq_migration_allowed=0
    }
    if [[ $pq_migration_allowed -eq 1 ]]; then
      if [[ -z "$pq_migration_answer" ]] || [[ "$pq_migration_answer" =~ ^[yYдД]$ ]]; then
        # Маркер предупреждения ставится ТОЛЬКО после успешной миграции (ниже):
        # иначе упавшая миграция повторялась бы уже молча, без предупреждения.
        pq_migration_answered_yes=1
      else
        echo -e "${YELLOW}PQ migration skipped. The warning will appear again on the next run.${NC}"
        pq_migration_allowed=0
      fi
    fi
  fi
  if [[ $pq_migration_allowed -eq 1 ]]; then
    if run_migration "pq_all_2026" "PQ: legacy-профили → XHTTP+PQ" _migrate_pq_all_profiles_2026; then
      # Предупреждение «исчерпано» только когда миграция реально прошла.
      if [[ $pq_migration_answered_yes -eq 1 ]]; then
        touch "$pq_migration_warned"
        chown xray:xray "$pq_migration_warned" 2>/dev/null || true
      fi
    else
      ((migration_failures++))
    fi
  fi
  run_migration "xhttp_default_2026"                   "XHTTP+PQ как дефолтный пресет создания профиля" _migrate_xhttp_default_2026 || ((migration_failures++))
  run_migration "subscription_tokens_2026"             "Subscription tokens (Phase 7) для существующих профилей" _migrate_subscription_tokens_2026 || ((migration_failures++))
  run_migration "happ_legacy_xhttp_route_2026"         "HAPP subscription не меняет существующие профили" _migrate_happ_legacy_xhttp_route_2026 || ((migration_failures++))

  if [[ ! -f /usr/local/etc/xray/.sni_list_2026 ]]; then
    echo -e "${YELLOW}Before the SNI migration you can run probe-test to check SNI availability.${NC}"
    echo -n -e "${YELLOW}Run probe-test now? [y/N]: ${NC}"
    local probe_ans
    read -r probe_ans
    probe_ans=${probe_ans:-N}
    if [[ "$probe_ans" =~ ^[yYдД]$ ]]; then
      probe_test_command
      echo -n -e "${YELLOW}Press Enter to continue the migration...${NC}"
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
    echo -e "${YELLOW}⚠ The legacy host TCP tuning cleanup did not finish. Check the sysctl configs manually.${NC}"
  fi

  # Aggregate report (RESEARCH §«Error reporting»): чтобы пользователь не пропустил
  # failure среди скроллящегося TUI вывода.
  if [[ $migration_failures -gt 0 ]]; then
    echo
    echo -e "${YELLOW}⚠ $migration_failures migrations did not finish — they will retry on the next run${NC}"
    echo -e "${YELLOW}  Backup logs: /usr/local/etc/xray/backups/${NC}"
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
    if declare -F wizard_is_fresh_install >/dev/null 2>&1 && wizard_is_fresh_install; then
      # Чистый сервер → мастер. При отказе не зацикливаемся: показываем статус.
      if declare -F run_first_run_wizard >/dev/null 2>&1; then
        run_first_run_wizard || true
      fi
    fi
    if declare -F status_screen >/dev/null 2>&1; then
      status_screen
      return 0
    fi
    # Fallback, если модули не подгружены — просто выход с подсказкой.
    echo -e "${RED}The wizard/status modules are not loaded. Rebuild with ./build.sh${NC}"
    return 1
  done
}

# Меню создания профиля
