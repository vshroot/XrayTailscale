#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}✗ This script must be run as root${NC}" 
   echo -e "${YELLOW}Use: sudo bash uninstall.sh${NC}"
   exit 1
fi

clear
echo -e "${RED}"
echo '═══════════════════════════════════════════════════════════'
echo '              REMOVING XRAYTAILSCALE                          '
echo '═══════════════════════════════════════════════════════════'
echo -e "${NC}\n"

echo -e "${YELLOW}This action will remove:${NC}"
echo -e "  ${BLUE}•${NC} Xray-core and all its components"
echo -e "  ${BLUE}•${NC} All profiles and configurations"
echo -e "  ${BLUE}•${NC} The xraytailscale app"
echo -e "  ${BLUE}•${NC} The generated Reality keys"
echo ""
echo -e "${RED}⚠ ALL DATA WILL BE LOST PERMANENTLY!${NC}"
echo ""
echo -n -e "${YELLOW}Are you sure you want to remove XrayTailscale? (yes/no): ${NC}"
read confirmation

if [[ "$confirmation" != "yes" ]]; then
    echo -e "${CYAN}✓ Removal cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}[1/6]${NC} ${YELLOW}Stopping the Xray service...${NC}"
systemctl stop xray > /dev/null 2>&1
systemctl disable xray > /dev/null 2>&1
echo -e "${GREEN}✓ Service stopped${NC}\n"

echo -e "${BLUE}[2/6]${NC} ${YELLOW}Removing Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove > /dev/null 2>&1
echo -e "${GREEN}✓ Xray-core removed${NC}\n"

echo -e "${BLUE}[3/6]${NC} ${YELLOW}Removing configurations and profiles...${NC}"
rm -rf /usr/local/etc/xray
echo -e "${GREEN}✓ Configurations removed${NC}\n"

echo -e "${BLUE}[4/6]${NC} ${YELLOW}Removing the xraytailscale app...${NC}"
rm -f /usr/local/bin/xraytailscale
rm -f /usr/local/bin/xraytailscale-update /usr/local/bin/xraytailscale-uninstall
legacy_cmd="xrayeba""tor"
rm -f "/usr/local/bin/${legacy_cmd}" "/usr/local/bin/${legacy_cmd}-update" "/usr/local/bin/${legacy_cmd}-uninstall" 2>/dev/null || true
echo -e "${GREEN}✓ App removed${NC}\n"

echo -e "${BLUE}[5/6]${NC} ${YELLOW}Cleaning systemd...${NC}"
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/xray@.service
systemctl daemon-reload > /dev/null 2>&1
echo -e "${GREEN}✓ Systemd cleaned${NC}\n"

echo -e "${BLUE}[6/6]${NC} ${YELLOW}Cleaning logs...${NC}"
journalctl --rotate > /dev/null 2>&1
journalctl --vacuum-time=1s > /dev/null 2>&1
echo -e "${GREEN}✓ Logs cleaned${NC}\n"

clear
echo -e "${GREEN}"
echo '═══════════════════════════════════════════════════════════'
echo '           ✓ REMOVAL COMPLETED SUCCESSFULLY!                   '
echo '═══════════════════════════════════════════════════════════'
echo -e "${NC}\n"

echo -e "${CYAN}XrayTailscale has been completely removed from your server.${NC}"
echo -e "${BLUE}Thanks for using it!${NC}\n"
