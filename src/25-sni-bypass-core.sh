_sni_in_use() {
  local domain="$1"
  local -ar REALITY_DEFAULT_SNIS=(
    "www.ozon.ru" "api-maps.yandex.ru" "www.sberbank.ru"
    "www.gosuslugi.ru" "www.tinkoff.ru" "www.alfabank.ru"
    "www.kinopoisk.ru" "speller.yandex.net" "www.cloudflare.com"
  )

  local d
  for d in "${REALITY_DEFAULT_SNIS[@]}"; do
    [[ "$d" == "$domain" ]] && return 0
  done

  if [[ -d "$PROFILES_DIR" ]]; then
    local profile_snis
    profile_snis=$(jq -r '.sni // empty' "$PROFILES_DIR"/*.json 2>/dev/null | sort -u)
    while IFS= read -r psni; do
      [[ -n "$psni" && "$psni" == "$domain" ]] && return 0
    done <<< "$profile_snis"
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    local cfg_snis
    cfg_snis=$(jq -r '[.inbounds[]? | .streamSettings.realitySettings.serverNames // [] | .[]] | .[]' "$CONFIG_FILE" 2>/dev/null | sort -u)
    while IFS= read -r csni; do
      [[ -n "$csni" && "$csni" == "$domain" ]] && return 0
    done <<< "$cfg_snis"
  fi

  return 1
}

_bypass_list_current() {
  jq -r '
    [.routing.rules[]?
     | select(.outboundTag == "direct" and (((.domain // []) | length) > 0))
     | .domain[]
    ] | unique | .[]
  ' "$CONFIG_FILE" 2>/dev/null
}

_apply_bypass_rule() {
  local domain_list_json="$1"
  local normalized_json
  if ! normalized_json=$(printf '%s' "$domain_list_json" | jq -c '
      if type == "array" and all(.[]; type == "string" and startswith("domain:")) then
        unique
      else
        error("invalid domain list")
      end
    ' 2>/dev/null); then
    echo -e "${RED}✗ Некорректный JSON domain-list для bypass${NC}"
    return 2
  fi

  local domain_count
  domain_count=$(printf '%s' "$normalized_json" | jq 'length' 2>/dev/null)
  if [[ "$domain_count" == "0" ]]; then
    echo -e "${YELLOW}Нет доменов для применения${NC}"
    return 1
  fi

  local domains_raw
  domains_raw=$(printf '%s' "$normalized_json" | jq -r '.[] | ltrimstr("domain:")')
  local dom
  while IFS= read -r dom; do
    [[ -z "$dom" ]] && continue
    if _sni_in_use "$dom"; then
      echo -e "${RED}Конфликт: $dom используется как Reality SNI — добавление сломает handshake${NC}"
      echo -e "${YELLOW}  Bypass правила не применены. Удалите $dom из списка и попробуйте снова.${NC}"
      return 1
    fi
  done <<< "$domains_raw"

  local rollback_config=""
  backup_config "bypass_routing_add" rollback_config || return 2
  # safe_jq_write routing.rules: PREPEND нового bypass-правила.
  if safe_jq_write \
      --argjson domains "$normalized_json" \
      '.routing.rules = [{"type":"field","domain":$domains,"outboundTag":"direct"}] + .routing.rules' \
      "$CONFIG_FILE"; then
    fix_xray_permissions
    if safe_restart_xray "$rollback_config"; then
      return 0
    fi
    return 2
  fi
  return 2
}

_bypass_remove_rule() {
  local d="domain:$1"
  local rollback_config=""
  backup_config "bypass_routing_remove" rollback_config || return 2
  # safe_jq_write routing.rules: удалить domain из bypass-правил.
  if safe_jq_write \
      --arg d "$d" \
      '.routing.rules = [
        .routing.rules[] |
        if (.outboundTag == "direct" and ((.domain // []) | type == "array")) then
          .domain = ((.domain // []) - [$d])
          | (if (.domain | length == 0) then empty else . end)
        else
          .
        end
      ]' "$CONFIG_FILE"; then
    fix_xray_permissions
    if safe_restart_xray "$rollback_config"; then
      return 0
    fi
    return 2
  fi
  return 2
}

_bypass_reset_all() {
  local rollback_config=""
  backup_config "bypass_routing_reset" rollback_config || return 2
  # safe_jq_write routing.rules: удалить только domain bypass-правила.
  if safe_jq_write '
      .routing.rules = [
        .routing.rules[] |
        select(.outboundTag != "direct" or (.network // null) != null or (.port // null) != null or (((.domain // []) | length) == 0))
      ]' "$CONFIG_FILE"; then
    fix_xray_permissions
    if safe_restart_xray "$rollback_config"; then
      return 0
    fi
    return 2
  fi
  return 2
}

_bypass_bundle_groups() {
  # Апекс-домены — Xray domain:<apex> делает subdomain-match, поддомены не нужны.
  # Аудит 2026-05: расширение покрытия antifraud/auth-эндпоинтов (Яндекс Лавка/Такси,
  # VK ID, Сбер ID, СБП/Mir, ESIA gu-st.ru), переход Тинькофф→T-Bank, Tele2→t2.ru,
  # появление национального мессенджера max.ru (OTP Госуслуг), Самокат под Сбером.
  cat <<'EOG'
yandex|Yandex (экосистема)|yandex.ru,yandex.net,yandex.com,ya.ru,ya.cc,yandex.by,yandex.kz,yastatic.net,yastat.net,yandexcloud.net,yandex.cloud,yandexadexchange.net,yandexwebcache.net,yandex-bank.net,yandexgo.com,yango.com,yango.taxi,yango-tech.com,naydex.net,clck.ru,turbopages.org,kinopoisk.ru,kp.ru,dzen.ru,mc.yandex.com,appmetrica.yandex.net,adfox.ru,meteum.ai,shedevrum.ai,berizaryad.ru,elama.ru
vk|VKontakte|vk.com,vk.ru,vk.me,vk.cc,vk.link,vk.design,vkontakte.ru,mvk.com,vkpay.ru,vkpay.com,userapi.com,userapi.ru,vk-cdn.net,vk-cdn.me,cdn-vk.net,cdn-vk.ru,vk-portal.net,vkcache.com,vkcdnservice.com,vkcloud-static.ru,vktech-static.ru,vkuser.net,vkuseraudio.net,vkuservideo.net,vkuservideo.ru,vkuserlive.net,vkuserphoto.ru,vkusercdn.ru,vkmessenger.com,vkvideo.ru,vkclips.app,vklive.app
mailru|VK Group / Mail.ru|mail.ru,my.com,my.games,list.ru,bk.ru,inbox.ru,internet.ru,ok.ru,odnoklassniki.ru,boom.ru,boosty.to,youla.ru,youla.io,rustore.ru,mcs.st,max.ru,oneme.ru,sferum.ru,tamtam.chat,mycdn.me,imgsmail.ru,smailru.net,mradx.net,mrgcdn.ru,datacloudmy.com,attachmail.ru,attachmy.com,appsmail.ru,staticmy.com,vmailru.net,bizmrg.com,target.my.com,vk.team,vk.company,vkfest.ru,vkplay.ru,yclients.com,skillbox.ru,skillfactory.ru,uchi.ru,gb.ru
banks|RU-банки и платежи|sberbank.ru,sber.ru,sberbank.com,sbrf.ru,sberid.ru,sbermarket.ru,sbermegamarket.ru,megamarket.ru,sberauto.com,sbercloud.ru,sberdevices.ru,sberdisk.ru,sberhealth.ru,sberleasing.ru,sberlogistics.ru,sbermobile.ru,sber.pro,sberspasibo.ru,spasibosberbank.ru,sbertech.ru,domclick.ru,tbank.ru,tinkoff.ru,tcsbank.ru,cdn-tinkoff.ru,t-static.ru,tinkoff-group.com,t-tech.ru,t-finance.ru,dolyame.ru,rosbank.ru,vtb.ru,pochtabank.ru,alfabank.ru,alfabank.st,alfadirect.ru,raiffeisen.ru,gazprombank.ru,gpb.ru,rshb.ru,psbank.ru,psb.ru,sovcombank.ru,mkb.ru,mtsbank.ru,otpbank.ru,uralsib.ru,bspb.ru,akbars.ru,tochka.com,domrfbank.ru,zenit.ru,yoomoney.ru,qiwi.com,qiwi.ru,nspk.ru,mironline.ru,mir-pay.ru,sbp.ru,cbr.ru
marketplaces|RU-маркетплейсы и retail|ozon.ru,ozon.travel,ozonbank.ru,ozonru.net,wildberries.ru,wb.ru,wbbasket.ru,wbstatic.net,avito.ru,avito.st,avito.tech,lamoda.ru,kuper.ru,samokat.ru,vkusvill.ru,magnit.ru,lenta.com,perekrestok.ru,pyaterochka.ru,auchan.ru,detmir.ru,mvideo.ru,citilink.ru,dns-shop.ru,eldorado.ru,fix-price.com,dodopizza.ru,dodois.com
ru_services|Госуслуги и телеком|gosuslugi.ru,gu-st.ru,nalog.ru,nalog.gov.ru,mos.ru,mosreg.ru,spb.ru,sevastopol.ru,gov.ru,government.ru,kremlin.ru,cikrf.ru,rkn.gov.ru,mvd.ru,mil.ru,sudrf.ru,rosreestr.ru,rosreestr.gov.ru,pfr.gov.ru,fss.ru,gibdd.ru,emias.info,edu.ru,goskey.ru,ebs.ru,pochta.ru,mts.ru,megafon.ru,beeline.ru,tele2.ru,t2.ru,yota.ru,rt.ru,rostelecom.ru
streaming|RU-стриминг и медиа|ivi.ru,ivi.tv,okko.tv,more.tv,premier.one,start.ru,kion.ru,wink.ru,megogo.net,megogo.ru,rutube.ru,smotrim.ru,1tv.ru,vgtrk.com,ren.tv,ntv.ru,tnt-online.ru,ctc.ru,2x2tv.ru,viju.ru,amediateka.ru,smotreshka.tv,zvuk.com,cdnvideo.ru,trbcdn.net,kinescopecdn.net,ngenix.net
steam|Steam|steamcontent.com,steamcdn-a.akamaihd.net,steam-chat.com,steamcommunity.com,cm.steampowered.com
EOG
}

probe_sni() {
  local sni="$1"
  local timeout=8
  local tls_out tls_status="FAIL"
  tls_out=$(timeout "$timeout" openssl s_client \
    -connect "${sni}:443" \
    -servername "$sni" \
    -tls1_3 \
    </dev/null 2>&1)
  echo "$tls_out" | grep -q "Verify return code: 0" && tls_status="OK"

  local http_code latency
  read -r http_code latency < <(
    curl -s -o /dev/null \
      --connect-timeout "$timeout" \
      --max-time "$timeout" \
      -w "%{http_code} %{time_total}" \
      "https://${sni}/" 2>/dev/null || echo "000 0"
  )

  printf "%-32s | %-10s | %-10s | %6ss\n" \
    "$sni" "${http_code:-000}" "TLS ${tls_status}" "${latency:-?}"
}

probe_test_command() {
  local sni_file="$SNI_LIST"
  if [[ ! -f "$sni_file" && -f /usr/local/etc/xray/sni_list.txt ]]; then
    sni_file="/usr/local/etc/xray/sni_list.txt"
  fi
  if [[ ! -f "$sni_file" ]]; then
    echo -e "${RED}✗ SNI list не найден: $SNI_LIST${NC}"
    return 1
  fi

  echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE} PROBE TEST: проверка SNI с VPS${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
  echo ""
  printf "${CYAN}%-32s | %-10s | %-10s | %6s${NC}\n" "SNI" "HTTP" "TLS" "latency"
  printf "%-32s-+-%-10s-+-%-10s-+-%6s\n" "--------------------------------" "----------" "----------" "------"

  local total=0
  local ok_count=0
  local sni category priority row
  while IFS='|' read -r sni category priority || [[ -n "$sni" ]]; do
    [[ "$sni" =~ ^#.*$ ]] && continue
    [[ "$sni" =~ ^[[:space:]]*$ ]] && continue
    [[ -z "$sni" ]] && continue

    row=$(probe_sni "$sni")
    echo "$row"
    ((total++))
    [[ "$row" == *"TLS OK"* ]] && ((ok_count++))
  done < "$sni_file"

  printf "%-32s-+-%-10s-+-%-10s-+-%6s\n" "--------------------------------" "----------" "----------" "------"
  echo -e "${GREEN}Доступны: ${ok_count}/${total} SNI${NC}"
}

# ═══════════════════════════════════════════════════════════
# END HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════

# Phase 7: при source-режиме НЕ делаем curl/hostname на загрузке (subhttp.sh source-ит
# xraytailscale на каждый HTTP-request — лишние сетевые вызовы под xray:xray неприемлемы).
# В source-режиме SERVER_IP инициализируется пустым; pure-функции берут публичный
# адрес из HAPP markers, а get_server_ip() используют только как fallback.
if [[ "$XRAYTAILSCALE_SOURCED" -eq 0 ]]; then
  SERVER_IP=$(get_server_ip)
else
  SERVER_IP=""
fi


# Показать ASCII арт
