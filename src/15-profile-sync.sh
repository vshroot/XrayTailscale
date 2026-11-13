profile_has_routes() {
  local profile_file=$1
  jq -e '(.routes // []) | length > 0' "$profile_file" >/dev/null 2>&1
}

# Select one route from a multi-route profile.
# Sets global SELECTED_ROUTE_INDEX on success.
select_route_for_profile() {
  local profile_file=$1
  local action_label=${2:-"изменения"}
  local route_count
  route_count=$(_profile_route_count "$profile_file")
  SELECTED_ROUTE_INDEX=""

  if [[ ! "$route_count" =~ ^[0-9]+$ ]] || [[ "$route_count" -le 0 ]]; then
    return 1
  fi

  echo ""
  echo -e "${YELLOW}Профиль содержит несколько маршрутов. Выберите маршрут для ${action_label}:${NC}\n"
  jq -r --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" '
    to_entries[] |
    "  \(.key + 1)) \(.value.label // .value.transport): \(.value.transport) :\(.value.port) sni=\(.value.sni // "n/a") fp=\(.value.fingerprint // $default_fp)"
  ' < <(jq '.routes // []' "$profile_file")
  echo -e "  ${CYAN}0)${NC} Назад"
  echo ""
  echo -n -e "${YELLOW}Маршрут: ${NC}"
  local route_choice
  read -r route_choice
  [[ "$route_choice" == "0" ]] && return 1
  if [[ ! "$route_choice" =~ ^[0-9]+$ ]] || [[ "$route_choice" -lt 1 ]] || [[ "$route_choice" -gt "$route_count" ]]; then
    echo -e "${RED}✗ Неверный выбор маршрута${NC}"
    sleep 2
    return 1
  fi

  SELECTED_ROUTE_INDEX=$((route_choice - 1))
  return 0
}

# Check if a profile references a port either as top-level profile port or route port.
profile_uses_port() {
  local profile_file=$1
  local port=$2
  jq -e --argjson port "$port" '
    (.port == $port) or any((.routes // [])[]; .port == $port)
  ' "$profile_file" >/dev/null 2>&1
}

# Get list of profile names using a specific port
# Args: $1=port
# Returns: space-separated profile names
get_profiles_on_port() {
  local port=$1
  local profiles=()

  for pf in "$PROFILES_DIR"/*.json; do
    [[ ! -f "$pf" ]] && continue
    [[ "$pf" == *"_test.json" ]] && continue

    if profile_uses_port "$pf" "$port"; then
      profiles+=("$(basename "$pf" .json)")
    fi
  done

  # Пустой массив: "${profiles[@]}" падает под set -u на bash < 4.4.
  ((${#profiles[@]})) && echo "${profiles[@]}"
  return 0
}

# Update field for all profiles on a specific port
# Args: $1=port, $2=field, $3=value
update_all_profiles_on_port() {
  local port=$1
  local field=$2
  local value=$3

  local profiles=($(get_profiles_on_port "$port"))
  local ok=true

  # Пусто — нечего обновлять (и "${profiles[@]}" не переживёт set -u на bash < 4.4).
  ((${#profiles[@]})) || return 0

  for pname in "${profiles[@]}"; do
    local pfile="$PROFILES_DIR/$pname.json"
    if safe_jq_write --argjson port "$port" --arg f "$field" --arg v "$value" '
      if .port == $port then .[$f] = $v else . end |
      # routes отсутствует у single-route профилей: (.routes // []) |= там падает
      # ("Invalid path expression"). Обновляем только реально существующий массив.
      if (.routes | type) == "array" then
        .routes |= map(if .port == $port then .[$f] = $v else . end)
      else . end
    ' "$pfile"; then
      echo -e "${CYAN}  → Обновлен: ${YELLOW}$pname${NC}"
    else
      echo -e "${RED}  ✗ Ошибка обновления: ${YELLOW}$pname${NC}"
      ok=false
    fi
  done
  [[ "$ok" == "true" ]]
}

# Update the client-side Reality fingerprint for exactly one profile route.
# Fingerprint controls the client's TLS ClientHello and is not an inbound/port setting.
# For route 0, keep the legacy top-level mirror in sync for older readers.
update_profile_fingerprint() {
  local profile_file=$1
  local route_index=$2
  local fingerprint=$3

  if [[ -n "$route_index" ]]; then
    safe_jq_write --argjson i "$route_index" --arg fp "$fingerprint" '
      if (.routes[$i] // null) == null then
        error("route not found")
      else
        .routes[$i].fingerprint = $fp |
        if $i == 0 then .fingerprint = $fp else . end
      end
    ' "$profile_file"
  else
    safe_jq_write --arg fp "$fingerprint" '.fingerprint = $fp' "$profile_file"
  fi
}

# Update the stored port for every profile/route that references old_port.
update_all_profiles_port_reference() {
  local old_port=$1
  local new_port=$2

  local profiles=($(get_profiles_on_port "$old_port"))
  local ok=true
  local pname
  ((${#profiles[@]})) || return 0
  for pname in "${profiles[@]}"; do
    local pfile="$PROFILES_DIR/$pname.json"
    if safe_jq_write --argjson old_port "$old_port" --argjson new_port "$new_port" '
      if .port == $old_port then .port = $new_port else . end |
      # См. выше: routes может отсутствовать — тогда (.routes // []) |= падает.
      if (.routes | type) == "array" then
        .routes |= map(if .port == $old_port then .port = $new_port else . end)
      else . end
    ' "$pfile"; then
      echo -e "${CYAN}  → Обновлен порт: ${YELLOW}$pname${NC}"
    else
      echo -e "${RED}  ✗ Ошибка обновления порта: ${YELLOW}$pname${NC}"
      ok=false
    fi
  done
  [[ "$ok" == "true" ]]
}

