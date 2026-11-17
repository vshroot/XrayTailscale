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
    selfsteal-auto)
      shift
      selfsteal_auto_command "$@"
      ;;
    wizard)
      shift
      wizard_command
      ;;
    ""|menu)
      main_menu
      ;;
    *)
      echo -e "${RED}✗ Unknown command: $1${NC}"
      echo -e "${YELLOW}Usage:${NC}"
      echo -e "  ${CYAN}sudo xraytailscale${NC}         - open the menu"
      echo -e "  ${CYAN}sudo xraytailscale update${NC}  - update Xray-core"
      echo -e "  ${CYAN}sudo xraytailscale subscription-repair${NC}  - repair stale HAPP profiles"
      echo -e "  ${CYAN}sudo xraytailscale bulk-repair${NC}  - alias for subscription-repair"
      echo -e "  ${CYAN}sudo xraytailscale probe-test${NC}  - check SNI availability from the VPS"
      echo -e "  ${CYAN}sudo xraytailscale selfsteal-auto <domain> [email]${NC}  - self-steal without the menu (auto-deploy)"
      echo -e "  ${CYAN}sudo xraytailscale wizard${NC}  - initial setup wizard (5 steps)"
      exit 1
      ;;
  esac
fi
