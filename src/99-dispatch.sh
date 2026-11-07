# CLI dispatch (Phase 5, REQ-B02). Subcommand-style.
# Без аргументов → interactive main_menu (legacy behaviour).
# При source-режиме (Phase 7, REQ-C10) dispatch пропускается — sourcing-скрипт сам решает,
# что делать с определёнными функциями.
if [[ "$XRAYTAILSCALE_SOURCED" -eq 0 ]]; then
  case "${1:-}" in
    update)
      shift
      update_command "$@"
      ;;
    probe-test)
      shift
      probe_test_command
      ;;
    bulk-repair|subscription-repair)
      shift
      repair_stale_subscription_profiles_core
      ;;
    ""|menu)
      main_menu
      ;;
    *)
      echo -e "${RED}✗ Неизвестная команда: $1${NC}"
      echo -e "${YELLOW}Использование:${NC}"
      echo -e "  ${CYAN}sudo xraytailscale${NC}         — открыть меню"
      echo -e "  ${CYAN}sudo xraytailscale update${NC}  — обновить Xray-core"
      echo -e "  ${CYAN}sudo xraytailscale subscription-repair${NC}  — восстановить stale HAPP profiles"
      echo -e "  ${CYAN}sudo xraytailscale bulk-repair${NC}  — alias для subscription-repair"
      echo -e "  ${CYAN}sudo xraytailscale probe-test${NC}  — проверить доступность SNI с VPS"
      exit 1
      ;;
  esac
fi
