# SSH access and listener changes. Keep the previous config until access is verified.

readonly SSHD_CONFIG=/etc/ssh/sshd_config
readonly SSH_DROPINS=/etc/ssh/sshd_config.d
readonly LEGACY_PORT_CONFIG="$SSH_DROPINS/00-debstart-ports.conf"
readonly SSH_SOCKET_CONFIG=/etc/systemd/system/ssh.socket.d/99-debstart-ports.conf
SSH_ACCESS_PENDING=0
SSH_ACCESS_RELOADED=0
SSH_LEGACY_ACCESS=()
SSH_PORT_PENDING=0
SSH_LISTENERS_CHANGED=0
SSH_SOCKET_ACTIVE=0
SSH_OLD_PORTS=()
SSH_SOCKET_ENDPOINTS=()

replace_sshd_config() {
  local temporary
  temporary=$(mktemp "${SSHD_CONFIG%/*}/.debstart-sshd.XXXXXXXX") || return
  if ! cp --attributes-only --preserve=mode,ownership -- "$SSHD_CONFIG" "$temporary" ||
     ! cat -- "$1" > "$temporary" ||
     ! mv -fT -- "$temporary" "$SSHD_CONFIG"; then
    rm -f -- "$temporary"
    return 1
  fi
}

sshd_body() {
  awk -v section="$1" '
    $0 == "# BEGIN DebStart " section { inside=1; next }
    $0 == "# END DebStart " section { inside=0; next }
    inside { next }
    {
      key=$0
      sub(/^[[:space:]]*/, "", key)
      sub(/[[:space:]=].*$/, "", key)
      gsub(/"/, "", key)
      key=tolower(key)
      if (section == "port" && key == "port") next
      if (section == "access" && key ~ /^(allowusers|permitrootlogin|authenticationmethods|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|clientaliveinterval|clientalivecountmax|tcpkeepalive)$/) next
      print
    }
    END { if (inside) exit 1 }
  ' "$2"
}

audit_sshd_access() {
  local candidate=$1 file
  local -a files
  /usr/sbin/sshd -t -f "$candidate" || return
  /usr/sbin/sshd -T -ddd -f "$candidate" >/dev/null 2>"$WORK_DIR/sshd-include.log" || return
  mapfile -t files < <(sed -n 's/\r$//; s/^debug2: load_server_config: filename //p' "$WORK_DIR/sshd-include.log")
  [[ ${files[0]:-} == "$candidate" ]] || return 1
  for file in "${files[@]}"; do
    awk -v main="$candidate" '
      {
        key=$0
        sub(/^[[:space:]]*/, "", key)
        sub(/[[:space:]=].*$/, "", key)
        gsub(/"/, "", key)
        key=tolower(key)
        if (key == "match") conditional=1
        if ((conditional && key == "include") ||
            (FILENAME != main && (key == "allowusers" ||
             (conditional && key ~ /^(permitrootlogin|authenticationmethods|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|clientaliveinterval|clientalivecountmax)$/)))) {
          printf "Правило SSH конфликтует с настройкой DebStart — %s:%d\n", FILENAME, FNR
          exit 1
        }
      }
    ' "$file" || return
  done
}

ssh_effective() {
  local user=$1 port=$2 config=${3:-$SSHD_CONFIG}
  local context="user=$user,host=$SSH_CLIENT_IP,addr=$SSH_CLIENT_IP"
  if [[ -n $SSH_LOCAL_ADDR ]]; then context+=",laddr=$SSH_LOCAL_ADDR"; fi
  if [[ -n $port ]]; then context+=",lport=$port"; fi
  /usr/sbin/sshd -T -f "$config" -C "$context"
}

verify_ssh_auth() {
  local port=$1 config=${2:-$SSHD_CONFIG} effective method=publickey password=no pubkey=yes
  if [[ $AUTH_MODE == password ]]; then
    method=password password=yes pubkey=no
  fi
  effective=$(ssh_effective "$ADMIN_USER" "$port" "$config") || return
  [[ $(awk '$1 == "allowusers" { $1=""; sub(/^ /, ""); print }' <<< "$effective") == "$ADMIN_USER" ]] &&
    grep -Fqx 'permitrootlogin no' <<< "$effective" &&
    grep -Fqx "authenticationmethods $method" <<< "$effective" &&
    grep -Fqx "passwordauthentication $password" <<< "$effective" &&
    grep -Fqx "pubkeyauthentication $pubkey" <<< "$effective" &&
    grep -Fqx 'kbdinteractiveauthentication no' <<< "$effective" &&
    grep -Fqx 'clientaliveinterval 60' <<< "$effective" &&
    grep -Fqx 'clientalivecountmax 10' <<< "$effective" &&
    grep -Fqx 'tcpkeepalive yes' <<< "$effective" || return
  if [[ $method == publickey ]]; then
    local keys
    keys=$(awk '$1 == "authorizedkeysfile" { $1=""; print }' <<< "$effective")
    [[ " $keys " == *' .ssh/authorized_keys '* || " $keys " == *' %h/.ssh/authorized_keys '* ||
       " $keys " == *" $ADMIN_HOME/.ssh/authorized_keys "* ]]
  fi
}

ssh_login_rules() {
  local effective
  effective=$(ssh_effective "$SSH_LOGIN" "$1" "${2:-$SSHD_CONFIG}") || return
  awk '$1 ~ /^(allowusers|denyusers|allowgroups|denygroups|permitrootlogin|authenticationmethods|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|authorizedkeysfile|authorizedkeyscommand|forcecommand|chrootdirectory)$/ { print }' <<< "$effective"
}

reload_ssh_auth() {
  if systemctl is-active --quiet ssh.service; then
    systemctl reload ssh.service
  else
    systemctl is-active --quiet ssh.socket
  fi
}

restore_ssh_access() {
  local file
  replace_sshd_config "$WORK_DIR/ssh-access.before" || return
  for file in "${SSH_LEGACY_ACCESS[@]}"; do
    cp -a -- "$WORK_DIR/legacy-access/${file##*/}" "$file" || return
  done
  if (( SSH_ACCESS_RELOADED )); then reload_ssh_auth || return; fi
  SSH_ACCESS_PENDING=0
  printf '%s\n' 'SSH · правила восстановлены'
}

configure_ssh() {
  local candidate="$WORK_DIR/sshd-access.conf" file method=publickey password=no pubkey=yes
  sudo -n -l -U "$ADMIN_USER" -u root -- /bin/sh >/dev/null 2>&1 ||
    fail "У $ADMIN_USER нет прав sudo. Выбери «Пользователь и sudo»."
  if [[ $AUTH_MODE == password ]]; then
    method=password password=yes pubkey=no
    passwd -S "$ADMIN_USER" | awk '$2 == "P" { ok=1 } END { exit !ok }' ||
      fail "У $ADMIN_USER нет активного пароля. Выбери «Пользователь и sudo»."
  else
    install_authorized_key
  fi
  install -d -m 0755 /run/sshd
  cp -a -- "$SSHD_CONFIG" "$WORK_DIR/ssh-access.before"
  if [[ ! -e $SSHD_CONFIG.before-debstart && ! -L $SSHD_CONFIG.before-debstart ]]; then
    cp -a -- "$SSHD_CONFIG" "$SSHD_CONFIG.before-debstart"
  fi
  mkdir "$WORK_DIR/legacy-access"
  SSH_LEGACY_ACCESS=()
  for file in "$SSH_DROPINS"/00-debstart-root.conf "$SSH_DROPINS"/90-debian-start-*.conf; do
    [[ -e $file || -L $file ]] || continue
    [[ -f $file && ! -L $file ]] || fail "Проверь файл SSH $file"
    cp -a -- "$file" "$WORK_DIR/legacy-access/"
    SSH_LEGACY_ACCESS+=("$file")
  done
  SSH_ACCESS_PENDING=1
  for file in "${SSH_LEGACY_ACCESS[@]}"; do rm -- "$file"; done
  {
    printf '# BEGIN DebStart access\nAllowUsers %s\nPermitRootLogin no\n' "$ADMIN_USER"
    printf 'AuthenticationMethods %s\nPubkeyAuthentication %s\nPasswordAuthentication %s\n' \
      "$method" "$pubkey" "$password"
    printf 'KbdInteractiveAuthentication no\n'
    printf 'ClientAliveInterval 60\nClientAliveCountMax 10\nTCPKeepAlive yes\n'
    printf '# END DebStart access\n'
    sshd_body access "$WORK_DIR/ssh-access.before"
  } > "$candidate"
  audit_sshd_access "$candidate" &&
    verify_ssh_auth "$SSH_LOCAL_PORT" "$candidate" || fail 'Проверь правила в sshd_config.'
  if [[ -n $SSH_LOCAL_PORT ]] && ! systemctl is-active --quiet ssh.socket &&
     ! sshd_ports "$candidate" | grep -Fx "$SSH_LOCAL_PORT" >/dev/null; then
    fail 'Порт активного сеанса отличается от sshd_config.'
  fi
  replace_sshd_config "$candidate"
  SSH_ACCESS_RELOADED=1
  printf '%s\n' 'SSH · применяю правила'
  reload_ssh_auth
  probe_ssh_listener "$SSH_PORT" || fail "SSH не ответил на порту $SSH_PORT."
  verify_running_login "$SSH_PORT" || fail "Не подтверждён вход для $ADMIN_USER."
  SSH_ACCESS_PENDING=0
  SSH_LOGIN=$ADMIN_USER
  printf 'SSH · доступ только для %s\n' "$ADMIN_USER"
}

sshd_ports() {
  local effective
  effective=$(/usr/sbin/sshd -T -f "${1:-$SSHD_CONFIG}") || return
  awk '$1 == "listenaddress" { sub(/^.*:/, "", $2); print $2 }' <<< "$effective" | sort -nu
}

ssh_listener_rows() {
  local sockets
  sockets=$(ss -H -lnt "sport = :$1") || return
  awk -v port="$1" '$4 ~ (":" port "$") { print }' <<< "$sockets"
}

ssh_listening() {
  local sockets
  sockets=$(ssh_listener_rows "$1") || return
  [[ -n $sockets ]]
}

ssh_socket_endpoints() {
  local listeners
  listeners=$(systemctl show --property=Listen --value ssh.socket) || return
  awk '{ for (i=2; i<=NF; i++) if ($i == "(Stream)" && $(i-1) ~ /(^|:)[0-9]+$/) print $(i-1) }' <<< "$listeners"
}

live_ssh_ports() {
  local ports pid sockets port
  if systemctl is-active --quiet ssh.socket; then
    ports=$(ssh_socket_endpoints) || return
    while IFS= read -r port; do
      if [[ -n $port ]] && ssh_listening "$port"; then printf '%s\n' "$port"; fi
    done < <(awk -F: 'NF {print $NF}' <<< "$ports" | sort -nu)
    return
  fi
  systemctl is-active --quiet ssh.service || return 1
  pid=$(systemctl show --property=MainPID --value ssh.service) || return
  sockets=$(ss -H -lntp) || return
  ports=$(awk -v pid="$pid" 'index($0, "pid=" pid ",") { sub(/^.*:/, "", $4); print $4 }' <<< "$sockets" | sort -nu)
  if [[ -n $ports ]]; then
    printf '%s\n' "$ports"
    return 0
  fi
  ports=$(sshd_ports) || return
  while IFS= read -r port; do
    if [[ -n $port ]] && ssh_listening "$port"; then printf '%s\n' "$port"; fi
  done <<< "$ports"
}

probe_ssh_listener() {
  local port=$1 effective path key sockets addr attempt
  local -a addresses=(127.0.0.1 ::1)
  local -A tried=()
  if [[ -n $SSH_LOCAL_ADDR ]]; then addresses=("$SSH_LOCAL_ADDR" "${addresses[@]}"); fi
  effective=$(/usr/sbin/sshd -T -f "$SSHD_CONFIG") || return
  : > "$WORK_DIR/ssh-probe.keys"
  while IFS= read -r path; do
    if key=$(ssh-keygen -y -P '' -f "$path" 2>/dev/null); then
      printf '%s\n' "$key" >> "$WORK_DIR/ssh-probe.keys"
    fi
  done < <(sed -n 's/^hostkey //p' <<< "$effective")
  [[ -s $WORK_DIR/ssh-probe.keys ]] || return 1
  wait_ssh_listener "$port" up || return
  sockets=$(ssh_listener_rows "$port") || return
  while IFS= read -r addr; do
    if [[ $addr != '*' && $addr != 0.0.0.0 && $addr != :: ]]; then addresses+=("$addr"); fi
  done < <(awk '{sub(/:[^:]*$/, "", $4); gsub(/^\[|\]$/, "", $4); print $4}' <<< "$sockets")
  for attempt in 1 2; do
    tried=()
    for addr in "${addresses[@]}"; do
      [[ $addr =~ ^[0-9A-Fa-f:.]+(%[a-zA-Z0-9_.-]+)?$ && -z ${tried[$addr]:-} ]] || continue
      tried[$addr]=1
      ssh-keyscan -T 2 -p "$port" "$addr" > "$WORK_DIR/ssh-probe.scan" 2>/dev/null || continue
      awk 'NR==FNR {known[$1 " " $2]=1; next} ($2 " " $3) in known' \
        "$WORK_DIR/ssh-probe.keys" "$WORK_DIR/ssh-probe.scan" > "$WORK_DIR/ssh-probe.known_hosts"
      if [[ -s $WORK_DIR/ssh-probe.known_hosts ]]; then
        SSH_PROBE_HOST=$addr
        return 0
      fi
    done
    sleep 0.2
  done
  return 1
}

verify_password_login() {
  local port=$1 login status=0
  printf '%s\n' "$LINUX_PASSWORD" > "$WORK_DIR/ssh-probe.password" || return
  printf '#!/bin/sh\nexec cat -- "%s/ssh-probe.password"\n' "$WORK_DIR" > "$WORK_DIR/ssh-askpass" || return
  chmod 0700 "$WORK_DIR/ssh-askpass" || return
  login=$(SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$WORK_DIR/ssh-askpass" \
    ssh -F /dev/null -nT -p "$port" -l "$ADMIN_USER" -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null \
      -o UserKnownHostsFile="$WORK_DIR/ssh-probe.known_hosts" \
      -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
      -- "$SSH_PROBE_HOST" id -un) || status=$?
  rm -f -- "$WORK_DIR/ssh-probe.password" "$WORK_DIR/ssh-askpass"
  [[ $status == 0 && $login == "$ADMIN_USER" ]]
}

verify_running_login() {
  local port=$1 expected=publickey
  if [[ -z $AUTH_MODE ]]; then return 0; fi
  if [[ $AUTH_MODE == password ]]; then
    if [[ -n ${LINUX_PASSWORD:-} ]]; then verify_password_login "$port"; return; fi
    expected=password
  fi
  ssh -F /dev/null -vnT -p "$port" -l "$ADMIN_USER" -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null \
    -o UserKnownHostsFile="$WORK_DIR/ssh-probe.known_hosts" -o BatchMode=yes \
    -o PreferredAuthentications=none -- "$SSH_PROBE_HOST" true \
    >/dev/null 2>"$WORK_DIR/ssh-probe.auth" || true
  sed 's/\r$//' "$WORK_DIR/ssh-probe.auth" |
    grep -Fx "debug1: Authentications that can continue: $expected" >/dev/null
}

reload_ssh_listeners() {
  if (( SSH_SOCKET_ACTIVE )); then
    local -a units=(ssh.socket)
    systemctl daemon-reload || return
    if systemctl is-active --quiet ssh.service; then
      [[ $(systemctl show --property=KillMode --value ssh.service) == process ]] || return 1
      units+=(ssh.service)
    fi
    printf 'SSH · перезапуск %s\n' "${units[*]}"
    systemctl restart "${units[@]}"
  elif [[ $(systemctl show --property=KillMode --value ssh.service) == process ]]; then
    printf '%s\n' 'SSH · перезапуск ssh.service'
    systemctl restart ssh.service
  else
    printf '%s\n' 'SSH · применяю порт'
    systemctl reload-or-restart ssh.service
  fi
}

restore_ssh_port() {
  replace_sshd_config "$WORK_DIR/ssh-ports.before" || return
  if [[ -e $WORK_DIR/legacy-port.before ]]; then
    cp -a -- "$WORK_DIR/legacy-port.before" "$LEGACY_PORT_CONFIG" || return
  fi
  if (( SSH_SOCKET_ACTIVE )); then
    if [[ -e $WORK_DIR/ssh-socket.before ]]; then
      cp -a -- "$WORK_DIR/ssh-socket.before" "$SSH_SOCKET_CONFIG" || return
    else
      rm -f -- "$SSH_SOCKET_CONFIG" || return
    fi
  fi
  if (( SSH_LISTENERS_CHANGED )); then reload_ssh_listeners || return; fi
  SSH_PORT_PENDING=0
  printf '%s\n' 'SSH · порт восстановлен'
}

write_ssh_ports() {
  {
    printf '# BEGIN DebStart port\n'
    printf 'Port %s\n' "$@"
    printf '# END DebStart port\n'
    sshd_body port "$WORK_DIR/ssh-ports.before"
  } > "$WORK_DIR/ssh-ports.conf"
}

write_ssh_socket() {
  local endpoint
  if (( ! SSH_SOCKET_ACTIVE )); then return; fi
  {
    printf '[Socket]\nListenStream=\n'
    {
      if [[ $1 == both ]]; then printf 'ListenStream=%s\n' "${SSH_SOCKET_ENDPOINTS[@]}"; fi
      for endpoint in "${SSH_SOCKET_ENDPOINTS[@]}"; do
        if [[ $endpoint == *:* ]]; then
          printf 'ListenStream=%s:%s\n' "${endpoint%:*}" "$SSH_NEW_PORT"
        else
          printf 'ListenStream=%s\n' "$SSH_NEW_PORT"
        fi
      done
    } | sort -u
  } > "$WORK_DIR/ssh-socket.conf"
  install -m 0644 "$WORK_DIR/ssh-socket.conf" "$SSH_SOCKET_CONFIG"
}

wait_ssh_listener() {
  local port=$1 state=$2 attempt sockets
  for ((attempt=0; attempt<25; attempt++)); do
    sockets=$(ssh_listener_rows "$port") || return
    if [[ -n $sockets && $state == up || -z $sockets && $state == down ]]; then return 0; fi
    sleep 0.2
  done
  return 1
}

change_ssh_port() {
  local current_ports port endpoint listeners old_rules new_rules
  install -d -m 0755 /etc/ssh/sshd_config.d /run/sshd
  SSH_SOCKET_ACTIVE=0
  if systemctl is-active --quiet ssh.socket; then
    SSH_SOCKET_ACTIVE=1
    if systemctl is-active --quiet ssh.service &&
       [[ $(systemctl show --property=KillMode --value ssh.service) != process ]]; then
      fail 'У ssh.service нестандартный KillMode. Перенос порта может прервать действующие сеансы.'
    fi
    listeners=$(ssh_socket_endpoints)
    mapfile -t SSH_SOCKET_ENDPOINTS <<< "$listeners"
    [[ -n $listeners ]] || fail 'Не удалось определить сокеты ssh.socket.'
    (( ${#SSH_SOCKET_ENDPOINTS[@]} )) || fail 'Не удалось определить сокеты ssh.socket.'
    for endpoint in "${SSH_SOCKET_ENDPOINTS[@]}"; do
      [[ $endpoint =~ ^([^/[:space:]]+:)?[0-9]+$ ]] || fail "Неподдерживаемый сокет SSH  $endpoint"
      printf -v current_ports '%s%s\n' "${current_ports:-}" "${endpoint##*:}"
    done
    current_ports=$(printf '%s' "$current_ports" | sort -nu)
  else
    systemctl is-active --quiet ssh.service || fail 'Для переноса порта запусти ssh.service или ssh.socket.'
    current_ports=$(live_ssh_ports)
  fi
  [[ -n $current_ports ]] || fail 'Не удалось определить текущие порты SSH.'
  if [[ $current_ports == "$SSH_NEW_PORT" ]] && ssh_listening "$SSH_NEW_PORT"; then
    probe_ssh_listener "$SSH_NEW_PORT" || fail "SSH не ответил на порту $SSH_NEW_PORT."
    printf 'SSH уже слушает порт %s.\n' "$SSH_NEW_PORT"
    return
  fi
  mapfile -t SSH_OLD_PORTS < <(grep -Fxv "$SSH_NEW_PORT" <<< "$current_ports" || true)
  for port in "${SSH_OLD_PORTS[@]}"; do
    [[ $port =~ ^[0-9]+$ ]] && ssh_listening "$port" || fail "Не найден действующий слушатель SSH  $port"
  done
  listeners=$(ssh_listener_rows "$SSH_NEW_PORT")
  if [[ -n $listeners ]] && ! grep -Fxq "$SSH_NEW_PORT" <<< "$current_ports"; then
    fail "Новый порт $SSH_NEW_PORT уже занят."
  fi

  old_rules=$(ssh_login_rules "$SSH_PORT")
  [[ ! -L $LEGACY_PORT_CONFIG && ! -L $SSH_SOCKET_CONFIG ]] || fail 'Проверь ссылки в настройках SSH.'
  cp -a -- "$SSHD_CONFIG" "$WORK_DIR/ssh-ports.before"
  if [[ -e $LEGACY_PORT_CONFIG ]]; then cp -a -- "$LEGACY_PORT_CONFIG" "$WORK_DIR/legacy-port.before"; fi
  if (( SSH_SOCKET_ACTIVE )); then
    install -d -m 0755 /etc/systemd/system/ssh.socket.d
    if [[ -e $SSH_SOCKET_CONFIG ]]; then cp -a -- "$SSH_SOCKET_CONFIG" "$WORK_DIR/ssh-socket.before"; fi
  fi
  SSH_PORT_PENDING=1
  if [[ -e $LEGACY_PORT_CONFIG ]]; then rm -- "$LEGACY_PORT_CONFIG"; fi
  write_ssh_ports "$SSH_NEW_PORT"
  [[ $(sshd_ports "$WORK_DIR/ssh-ports.conf") == "$SSH_NEW_PORT" ]] ||
    fail 'Проверь дополнительные Port и ListenAddress в настройках SSH.'
  new_rules=$(ssh_login_rules "$SSH_NEW_PORT" "$WORK_DIR/ssh-ports.conf")
  [[ $old_rules == "$new_rules" ]] || fail 'На новом порту действуют другие правила входа SSH.'

  write_ssh_ports "$SSH_NEW_PORT" "${SSH_OLD_PORTS[@]}"
  /usr/sbin/sshd -t -f "$WORK_DIR/ssh-ports.conf"
  replace_sshd_config "$WORK_DIR/ssh-ports.conf"
  write_ssh_socket both
  SSH_LISTENERS_CHANGED=1
  reload_ssh_listeners
  probe_ssh_listener "$SSH_NEW_PORT" || fail "SSH не ответил на порту $SSH_NEW_PORT."
  for port in "${SSH_OLD_PORTS[@]}"; do
    wait_ssh_listener "$port" up || fail "SSH потерял старый слушатель $port."
  done
  finish_ssh_port
}

finish_ssh_port() {
  local port
  write_ssh_ports "$SSH_NEW_PORT"
  [[ $(sshd_ports "$WORK_DIR/ssh-ports.conf") == "$SSH_NEW_PORT" ]] || fail 'Настройки SSH изменились.'
  replace_sshd_config "$WORK_DIR/ssh-ports.conf"
  write_ssh_socket new
  reload_ssh_listeners
  probe_ssh_listener "$SSH_NEW_PORT" || fail "SSH не ответил на порту $SSH_NEW_PORT."
  verify_running_login "$SSH_NEW_PORT" || fail "Не подтверждён вход на порту $SSH_NEW_PORT."
  for port in "${SSH_OLD_PORTS[@]}"; do
    wait_ssh_listener "$port" down || fail "Старый порт $port всё ещё слушает."
  done
  SSH_PORT=$SSH_NEW_PORT
  SSH_LOCAL_PORT=$SSH_NEW_PORT
  SSH_PORT_PENDING=0
  printf 'SSH · порт %s\n' "$SSH_PORT"
}
