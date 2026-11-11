#!/usr/bin/env bash
set +x
set -Eeuo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C.UTF-8
umask 077

INSTALLER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/installer" && pwd -P)
readonly INSTALLER_DIR
readonly PYTHON_VERSION=3.15.2 DRY_VERSION=v0.13.0 LOG_FILE=/var/log/debian-start.log
WORK_DIR=
KEY_EXPORT_DIR=
KEY_EXPORT_READY=0
PRIVATE_SCREEN=0
DIALOG_AVAILABLE=0
APT_READY=0
CURRENT_STAGE='Подготовка'
XUI_READY=0
declare -A STAGES=()
declare -ar EXTRA_ORDER=(
  install_packages install_shell install_python install_docker install_xui install_dry
)
declare -ar STAGE_ORDER=(
  change_root_password setup_admin_user configure_ssh set_server_hostname change_ssh_port "${EXTRA_ORDER[@]}"
)
declare -Ar STAGE_LABELS=(
  [change_root_password]='Пароль root'
  [setup_admin_user]='Пользователь и sudo'
  [configure_ssh]='Доступ SSH'
  [set_server_hostname]='Имя хоста'
  [change_ssh_port]='Порт SSH'
  [install_packages]='Пакеты APT'
  [install_shell]='Oh My Zsh и скины MC'
  [install_python]="Python $PYTHON_VERSION"
  [install_docker]='Docker и Compose'
  [install_xui]='3x-ui'
  [install_dry]="dry $DRY_VERSION"
)

source "$INSTALLER_DIR/lib/system.sh"
source "$INSTALLER_DIR/lib/ssh.sh"
source "$INSTALLER_DIR/lib/panels.sh"

fail() {
  printf '%s\n' "$1" >&2
  if [[ -n $WORK_DIR ]]; then printf 'Журнал  %s\n' "$LOG_FILE" >&2; fi
  exit 1
}

on_error() {
  local status=$1
  trap - ERR
  if (( BASH_SUBSHELL == 0 )); then
    printf 'Ошибка · %s (%s)\nЖурнал  %s\n' "$CURRENT_STAGE" "$status" "$LOG_FILE" >&2
    if (( KEY_EXPORT_READY )); then printf 'Временный ключ  %s\n' "$KEY_EXPORT_DIR" >&2; fi
  fi
  exit "$status"
}

close_private_screen() {
  if (( PRIVATE_SCREEN )); then
    tput rmcup >&3 2>/dev/null || true
    PRIVATE_SCREEN=0
  fi
}

cleanup() {
  close_private_screen
  if { (( SSH_PORT_PENDING )) && ! restore_ssh_port; } ||
     { (( SSH_ACCESS_PENDING )) && ! restore_ssh_access; }; then
    printf 'Проверь восстановление SSH. Копии  %s\n' "$WORK_DIR" >&2
    return
  fi
  if [[ -n $KEY_EXPORT_DIR && $KEY_EXPORT_READY == 0 ]]; then rm -rf -- "$KEY_EXPORT_DIR"; fi
  if [[ -n $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi
}

cancel() {
  printf '\nНастройка прервана.\n' >&3
  exit 0
}

section() {
  CURRENT_STAGE=$1
  printf '\n╭─ %s ─╮\n' "$CURRENT_STAGE" >&3
}

ui() {
  dialog --backtitle 'DebStart · Настройка сервера' --title "$CURRENT_STAGE" \
    --ok-label 'Далее' --cancel-label 'Отмена' "$@" 2>&1 1>&3 <&3
}

read_prompt() {
  local value
  printf '%s ' "$1" >&3
  IFS= read -r value <&3 || return 1
  printf '%s' "$value"
}

prompt_value() {
  if (( DIALOG_AVAILABLE )); then
    ui --inputbox "$1" 8 70 "${2:-}"
  elif [[ -n ${2:-} ]]; then
    read_prompt "$1 [$2]"
  else
    read_prompt "$1"
  fi
}

read_secret() {
  local secret
  if (( DIALOG_AVAILABLE )); then
    ui --passwordbox "$1" 8 70
  else
    printf '%s  ' "$1" >&3
    IFS= read -rs secret <&3 || return 1
    printf '\n' >&3
    printf '%s' "$secret"
  fi
}

step() {
  CURRENT_STAGE=$1
  shift
  printf '\n▶ %s\n' "$CURRENT_STAGE"
  "$@"
  printf '✓ %s\n' "$CURRENT_STAGE"
}

run_live() {
  local log_file=$1 logger_pid
  shift
  # Keep stage state in this shell. Interactive prompts explicitly use fd 3.
  {
    logger_pid=$!
    "$@"
  } </dev/null > >(tee -a -- "$log_file" >&3) 2>&1
  wait "$logger_pid"
}

run_step() {
  run_live "$LOG_FILE" step "$@"
}

selected() {
  [[ ${STAGES[$1]:-off} == on ]]
}

prompt_password() {
  local label=$1 optional=${2:-0} password confirmation
  while true; do
    password=$(read_secret "$label") || return 1
    if (( optional )) && [[ -z $password ]]; then return; fi
    confirmation=$(read_secret 'Повтори пароль') || return 1
    if [[ -n $password && $password == "$confirmation" ]]; then
      printf '%s' "$password"
      return
    fi
    printf '%s\n' 'Введи непустой пароль дважды.' >&3
  done
}

ask_admin_user() {
  local uid default_user=ops label='Логин'
  if [[ ${SSH_LOGIN:-root} != root ]]; then default_user=$SSH_LOGIN; fi
  if ! selected setup_admin_user; then label='Существующая учётка'; fi
  while true; do
    ADMIN_USER=$(prompt_value "$label" "$default_user") || cancel
    ADMIN_USER=${ADMIN_USER:-$default_user}
    if [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $ADMIN_USER != root ]]; then
      uid=$(id -u "$ADMIN_USER" 2>/dev/null || true)
      if [[ -z $uid ]]; then
        if selected setup_admin_user; then ADMIN_HOME=; return; fi
      elif (( uid >= 1000 && uid != 65534 )); then
        ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
        return
      fi
    fi
    printf '%s\n' 'Укажи обычную учётку Linux.' >&3
  done
}

ask_auth() {
  local choice
  if (( DIALOG_AVAILABLE )); then
    AUTH_MODE=$(ui --menu 'Вход по SSH' 12 70 3 key 'Свой ключ' generate 'Новый Ed25519' password 'Пароль') || cancel
  else
    printf '%s\n' '1 · Свой ключ   2 · Новый Ed25519   3 · Пароль' >&3
    while true; do
      choice=$(read_prompt 'Вход по SSH [1]') || cancel
      case "${choice:-1}" in
        1) AUTH_MODE=key; break ;;
        2) AUTH_MODE=generate; break ;;
        3) AUTH_MODE=password; break ;;
      esac
      printf '%s\n' 'Выбери 1, 2 или 3.' >&3
    done
  fi
  if [[ $AUTH_MODE != key ]]; then return; fi
  while true; do
    SSH_PUBLIC_KEY=$(prompt_value 'Вставь строку из файла .pub') || cancel
    SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY%$'\r'}
    if check_pubkey "$SSH_PUBLIC_KEY"; then return; fi
    printf '%s\n' 'Нужен публичный ключ OpenSSH.' >&3
  done
}

ask_port() {
  local title=$1 default_port=$2 value
  while true; do
    value=$(prompt_value "$title" "$default_port") || return 1
    value=${value:-$default_port}
    if [[ $value =~ ^[0-9]{1,5}$ ]] && (( 10#$value >= 1 && 10#$value <= 65535 )); then
      printf '%d' "$((10#$value))"
      return
    fi
    printf '%s\n' 'Укажи порт от 1 до 65535.' >&3
  done
}

detect_ssh_context() {
  local client_port ports login effective
  IFS=' ' read -r SSH_CLIENT_IP client_port SSH_LOCAL_ADDR SSH_LOCAL_PORT <<< "${SSH_CONNECTION:-}"
  SSH_CLIENT_IP=${SSH_CLIENT_IP:-127.0.0.1}
  SSH_HOST=${SSH_LOCAL_ADDR:-$(hostname -I | awk 'NR==1 {print $1}')}
  SSH_HOST=${SSH_HOST:-$(hostname)}
  SSH_PORT=${SSH_LOCAL_PORT:-22}
  if ports=$(live_ssh_ports 2>/dev/null) && [[ -n $ports ]]; then
    if ! grep -Fxq "$SSH_PORT" <<< "$ports"; then SSH_PORT=${ports%%$'\n'*}; fi
  elif selected configure_ssh || selected change_ssh_port; then
    fail 'Не найден работающий SSH.'
  fi
  SSH_LOCAL_PORT=$SSH_PORT
  login=${SUDO_USER:-$(logname 2>/dev/null || true)}
  SSH_LOGIN=${login:-root}
  if effective=$(/usr/sbin/sshd -T -f "$SSHD_CONFIG" 2>/dev/null); then
    login=$(awk '$1=="allowusers" { $1=""; sub(/^ /,""); print }' <<< "$effective")
    if [[ $login =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] && getent passwd "$login" >/dev/null; then
      SSH_LOGIN=$login
    fi
  fi
}

ask_ssh_host() {
  local address=$SSH_HOST
  while true; do
    SSH_HOST=$(prompt_value 'IP или домен для SCP' "$address") || cancel
    SSH_HOST=${SSH_HOST:-$address}
    if [[ $SSH_HOST =~ ^[a-zA-Z0-9:][a-zA-Z0-9.:-]*$ && ( $SSH_HOST != *:* || $SSH_HOST == *:*:* ) ]]; then
      break
    fi
    printf '%s\n' 'Укажи IP или домен без порта.' >&3
  done
}

ask_hostname() {
  while true; do
    SERVER_NAME=$(prompt_value 'Имя хоста' server) || cancel
    SERVER_NAME=${SERVER_NAME:-server}
    if [[ $SERVER_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
      SERVER_NAME=${SERVER_NAME,,}
      return
    fi
    printf '%s\n' 'Используй буквы A–Z, цифры и дефисы.' >&3
  done
}

ssh_key_name() {
  printf '%s-ed25519' "$ADMIN_USER"
}

ssh_arguments() {
  printf '%s' "-S none -p $1"
  if [[ $AUTH_MODE == password ]]; then
    printf ' %s' '-o PreferredAuthentications=password'
  elif (( KEY_EXPORT_READY )); then
    printf ' -i ./%s -o IdentitiesOnly=yes' "$(ssh_key_name)"
  fi
}

print_key_copy() {
  local scp_host=$SSH_HOST
  if [[ $scp_host == *:* ]]; then scp_host="[$scp_host]"; fi
  printf 'scp -P %s "%s@%s:%s/id_ed25519" "./%s"\n' \
    "$SSH_PORT" "$KEY_EXPORT_OWNER" "$scp_host" "$KEY_EXPORT_DIR" "$(ssh_key_name)"
}

apply_skipped_stages() {
  local reply=$1 token first last number stage
  shift
  local -a available=("$@") choices=()
  local -A skipped=()
  reply=${reply//–/-}
  reply=${reply//—/-}
  read -ra choices <<< "$reply"
  for token in "${choices[@]}"; do
    [[ $token =~ ^([1-9][0-9]?)(-([1-9][0-9]?))?$ ]] || return 1
    first=${BASH_REMATCH[1]}
    last=${BASH_REMATCH[3]:-$first}
    (( first <= last && last <= ${#available[@]} )) || return 1
    for ((number=first; number<=last; number++)); do
      skipped[${available[number-1]}]=1
    done
  done
  STAGES=()
  for stage in "${available[@]}"; do
    if [[ -z ${skipped[$stage]:-} ]]; then STAGES[$stage]=on; fi
  done
}

confirm_stage_plan() {
  local CURRENT_STAGE='План установки'
  local stage action plan= answer
  for stage in "$@"; do
    action='Пропустить'
    if selected "$stage"; then action='Запустить '; fi
    plan+="$action · ${STAGE_LABELS[$stage]}"$'\n'
  done
  if (( DIALOG_AVAILABLE )); then
    if ui --cr-wrap --defaultno --yes-label 'Запустить' --no-label 'Изменить' \
      --yesno "$plan" 18 70; then return 0
    elif [[ $? != 1 ]]; then cancel
    fi
    return 1
  fi
  printf '\n╭─ План установки ─╮\n%s' "$plan" >&3
  answer=$(read_prompt 'д — запустить, Enter — изменить.') || cancel
  [[ ${answer,,} == д || ${answer,,} == y ]]
}

ask_stages() {
  local CURRENT_STAGE='Какие этапы пропустить?'
  local stage reply= problem label numbered= index=0
  local hint=$'Пример ввода · 1 3 7 или 1-3 7\nПустой ввод — выполнить все после подтверждения.'
  for stage in "${STAGE_ORDER[@]}"; do
    index=$((index+1))
    printf -v label '%2d · %s' "$index" "${STAGE_LABELS[$stage]}"
    numbered+="$label"$'\n'
  done
  while true; do
    if (( DIALOG_AVAILABLE )); then
      reply=$(ui --cr-wrap --inputbox "$numbered$hint" 19 70 "$reply") || cancel
    else
      printf '\n╭─ Этапы установки ─╮\n%s%s\n' "$numbered" "$hint" >&3
      reply=$(read_prompt "$CURRENT_STAGE") || cancel
    fi
    if apply_skipped_stages "$reply" "${STAGE_ORDER[@]}"; then
      if [[ -z ${STAGES[*]:-} ]]; then return; fi
      if problem=$(check_plan); then
        if confirm_stage_plan "${STAGE_ORDER[@]}"; then return; fi
        continue
      fi
    else
      problem="Проверь номера от 1 до ${#STAGE_ORDER[@]} и порядок в диапазоне."
    fi
    if (( DIALOG_AVAILABLE )); then ui --msgbox "$problem" 8 70 || cancel
    else printf '%s\n' "$problem" >&3
    fi
  done
}

check_plan() {
  local tool
  local -a needed=()
  if selected setup_admin_user || selected configure_ssh; then
    command -v sudo >/dev/null && getent group sudo >/dev/null || {
      printf '%s\n' 'Нужны sudo и группа sudo.'
      return 1
    }
  fi
  if selected configure_ssh || selected change_ssh_port; then
    for tool in ssh ssh-keygen ssh-keyscan ss /usr/sbin/sshd; do
      if ! command -v "$tool" >/dev/null; then
        printf 'Нужен %s. Установи OpenSSH и iproute2.\n' "$tool"
        return 1
      fi
    done
    if [[ ! -f $SSHD_CONFIG || -L $SSHD_CONFIG ]]; then
      printf '%s\n' 'Проверь /etc/ssh/sshd_config.'
      return 1
    fi
  fi
  if ! selected install_packages; then
    if selected install_shell; then needed+=(git curl zsh fzf mc); fi
    if selected install_docker && ! docker_local compose version >/dev/null 2>&1; then needed+=(curl); fi
    if selected install_dry; then needed+=(curl python3); fi
    if selected install_xui; then needed+=(curl openssl ss); fi
    for tool in "${needed[@]}"; do
      if ! command -v "$tool" >/dev/null; then
        printf 'Нужен %s. Убери «Пакеты APT» из списка пропуска.\n' "$tool"
        return 1
      fi
    done
  fi
  if ! selected install_docker; then
    if { selected install_xui || selected install_dry; } &&
       ! docker_local info >/dev/null 2>&1; then
      printf '%s\n' 'Убери «Docker и Compose» из списка пропуска.'
      return 1
    fi
    if selected install_xui && ! docker_local compose version >/dev/null 2>&1; then
      printf '%s\n' 'Для 3x-ui нужен Compose.'
      return 1
    fi
  fi
}

run_stages() {
  local stage
  for stage in "${EXTRA_ORDER[@]}"; do
    if selected "$stage"; then step "${STAGE_LABELS[$stage]}" "$stage"; fi
  done
}

run_setup() {
  local default_port
  ADMIN_USER= ADMIN_HOME= AUTH_MODE=
  unset ROOT_NEW_PASSWORD LINUX_PASSWORD
  CURRENT_STAGE='Этапы установки'
  ask_stages
  if [[ -z ${STAGES[*]:-} ]]; then printf '%s\n' 'Все этапы пропущены.' >&3; return; fi
  detect_ssh_context
  SERVER_NAME=$(hostname -s)
  if selected change_root_password; then
    section 'Пароль root'
    ROOT_NEW_PASSWORD=$(prompt_password 'Новый пароль root') || cancel
    run_step 'Пароль root' change_root_password
  fi
  if selected setup_admin_user; then
    section 'Пользователь и sudo'
    ask_admin_user
    if [[ -n $ADMIN_HOME ]]; then
      LINUX_PASSWORD=$(prompt_password 'Новый пароль для sudo. Enter — оставить текущий.' 1) || cancel
    else
      LINUX_PASSWORD=$(prompt_password "Пароль $ADMIN_USER для sudo") || cancel
    fi
    run_step 'Пользователь и sudo' setup_admin_user
  fi
  if selected configure_ssh; then
    section 'Доступ SSH'
    if [[ -z $ADMIN_USER ]]; then ask_admin_user; fi
    ask_auth
    if [[ $AUTH_MODE == generate ]]; then ask_ssh_host; fi
    run_step 'Доступ SSH' configure_ssh
  fi
  if selected set_server_hostname; then
    section 'Имя хоста'
    ask_hostname
    run_step 'Имя хоста' set_server_hostname
  fi
  if selected change_ssh_port; then
    section 'Порт SSH'
    default_port=$SSH_PORT
    if [[ $default_port == 22 ]]; then default_port=2233; fi
    SSH_NEW_PORT=$(ask_port 'Новый порт SSH' "$default_port") || cancel
    run_step 'Порт SSH' change_ssh_port
  fi
  unset LINUX_PASSWORD
  if { selected install_shell || selected install_python; } && [[ -z $ADMIN_USER ]]; then
    section 'Профиль пользователя'
    ask_admin_user
  fi
  run_live "$LOG_FILE" run_stages
}

show_panel_password() {
  local panel=$1 answer
  if [[ -z $PANEL_PASSWORD ]]; then return; fi
  if (( DIALOG_AVAILABLE )); then
    CURRENT_STAGE="$panel · Доступ"
    printf 'URL     http://127.0.0.1:%s/%s/\nЛогин   %s\nПароль  %s\n' \
      "$PANEL_PORT" "$PANEL_PATH" "$PANEL_USER" "$PANEL_PASSWORD" > "$WORK_DIR/panel.txt"
    if ui --exit-label 'Сохранено' --textbox "$WORK_DIR/panel.txt" 13 70; then
      acknowledge_panel_login "/opt/$panel"
    fi
    return
  fi
  if command -v tput >/dev/null && tput smcup >&3 2>/dev/null; then PRIVATE_SCREEN=1; fi
  section "$panel · Доступ"
  printf 'URL     http://127.0.0.1:%s/%s/\nЛогин   %s\nПароль  %s\n' \
    "$PANEL_PORT" "$PANEL_PATH" "$PANEL_USER" "$PANEL_PASSWORD" >&3
  answer=$(read_prompt 'Enter — данные сохранены, q — позже') || answer=q
  close_private_screen
  if [[ -z $answer ]]; then acknowledge_panel_login "/opt/$panel"; fi
}

show_access_cards() {
  local ssh_args
  ssh_args=$(ssh_arguments "$SSH_PORT")
  section 'Готово'
  printf 'Хост  %s\nSSH   %s · порт %s\nssh %s %s@%s\n' \
    "$SERVER_NAME" "$SSH_LOGIN" "$SSH_PORT" "$ssh_args" "$SSH_LOGIN" "$SSH_HOST" >&3
  if (( XUI_READY )); then
    load_panel_state /opt/3x-ui
    printf '3x-ui    127.0.0.1:%s\n' "$PANEL_PORT" >&3
    show_panel_password 3x-ui
    printf '\n3x-ui · Туннель с компьютера\n' >&3
    printf 'ssh %s -o ExitOnForwardFailure=yes -N -L 127.0.0.1:%s:127.0.0.1:%s %s@%s\n' \
      "$ssh_args" "$PANEL_PORT" "$PANEL_PORT" "$SSH_LOGIN" "$SSH_HOST" >&3
    printf 'URL     http://127.0.0.1:%s/%s/\nЛогин   %s\n' "$PANEL_PORT" "$PANEL_PATH" "$PANEL_USER" >&3
  else
    printf '%s\n' '3x-ui    пропущено' >&3
  fi
  printf '\nЖурнал  %s\n' "$LOG_FILE" >&3
}

main() {
  local rows cols
  if [[ ${1:-} == --help ]]; then
    printf '%s\n' 'DebStart · Debian 12/13 и Ubuntu 22.04/24.04/26.04 LTS' 'sudo bash bootstrap.sh'
    return
  fi
  [[ $# -eq 0 ]] || fail 'Поддерживается только --help.'
  (( EUID == 0 )) || fail 'Запусти sudo bash bootstrap.sh.'
  [[ -t 0 && -t 1 ]] || fail 'Запусти мастер в терминале.'
  detect_platform
  [[ -d /run/systemd/system ]] || fail 'Нужен запущенный systemd.'
  ARCH=$(dpkg --print-architecture)
  [[ $ARCH == amd64 || $ARCH == arm64 ]] || fail 'Нужна архитектура amd64 или arm64.'
  exec 3<>/dev/tty
  read -r rows cols <<< "$(stty size <&3 2>/dev/null || true)"
  if [[ ${TERM:-dumb} != dumb ]] && (( ${rows:-0} >= 20 && ${cols:-0} >= 72 )) &&
     command -v dialog >/dev/null; then DIALOG_AVAILABLE=1; fi
  exec 8>/run/debian-start.lock
  flock -n 8 || fail 'DebStart уже запущен.'
  [[ ! -L $LOG_FILE ]] || fail "Проверь $LOG_FILE."
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  WORK_DIR=$(mktemp -d /run/debian-start.XXXXXXXX)
  trap cleanup EXIT
  trap 'on_error $?' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  printf 'DebStart · %s\n' "$DISTRO_LABEL" >&3
  run_setup
  if [[ -z ${STAGES[*]:-} ]]; then return; fi
  show_access_cards
  if (( KEY_EXPORT_READY )); then
    local answer
    answer=$(read_prompt 'Удалить копию SSH-ключа с сервера? [д/Н]') || answer=
    if [[ $answer == д || $answer == y ]]; then rm -rf -- "$KEY_EXPORT_DIR"; fi
  fi
  if selected install_shell; then
    CURRENT_STAGE='Zsh'
    printf '\nОткрываю Zsh под %s. exit — вернуться.\n' "$ADMIN_USER" >&3
    cleanup
    trap - EXIT
    exec 8>&- 3>&-
    exec runuser --pty --login --shell "$(command -v zsh)" "$ADMIN_USER"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
