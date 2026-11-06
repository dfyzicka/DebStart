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
APT_READY=0
CURRENT_STAGE='Подготовка'
READY_PANELS=()
declare -A STAGES=()
declare -ar EXTRA_ORDER=(
  install_packages install_shell install_python install_docker install_xui install_mui install_dry
)
declare -Ar EXTRA_LABELS=(
  [install_packages]='Пакеты APT'
  [install_shell]='Oh My Zsh и скины MC'
  [install_python]="Python $PYTHON_VERSION"
  [install_docker]='Docker и Compose'
  [install_xui]='3x-ui'
  [install_mui]='m-ui'
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
  printf '\n── %s ──\n' "$CURRENT_STAGE" >&3
}

read_prompt() {
  local value
  printf '%s ' "$1" >&3
  IFS= read -r value <&3 || return 1
  printf '%s' "$value"
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
  # Keep state changes from shell functions in the current process.
  {
    logger_pid=$!
    "$@"
  } > >(tee -a -- "$log_file" >&3) 2>&1
  wait "$logger_pid"
}

run_step() {
  run_live "$LOG_FILE" step "$@"
}

selected() {
  [[ ${STAGES[$1]:-off} == on ]]
}

prompt_password() {
  local label=$1 password confirmation
  while true; do
    printf '%s ' "$label" >&3
    IFS= read -rs password <&3 || return 1
    printf '\nПовтори пароль  ' >&3
    IFS= read -rs confirmation <&3 || return 1
    printf '\n' >&3
    if [[ -n $password && $password == "$confirmation" ]]; then
      printf '%s' "$password"
      return
    fi
    printf '%s\n' 'Введи непустой пароль дважды.' >&3
  done
}

ask_admin_user() {
  local uid
  while true; do
    ADMIN_USER=$(read_prompt 'Логин [ops]') || cancel
    ADMIN_USER=${ADMIN_USER:-ops}
    if [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $ADMIN_USER != root ]]; then
      uid=$(id -u "$ADMIN_USER" 2>/dev/null || true)
      if [[ -z $uid ]] || (( uid >= 1000 && uid != 65534 )); then return; fi
    fi
    printf '%s\n' 'Укажи обычный логин Linux.' >&3
  done
}

ask_auth() {
  local choice
  printf '%s\n' '1 · Свой ключ   2 · Новый Ed25519   3 · Пароль' >&3
  while true; do
    choice=$(read_prompt 'Вход по SSH [1]') || cancel
    case "${choice:-1}" in
      1) AUTH_MODE=key; break ;;
      2) AUTH_MODE=generate; return ;;
      3) AUTH_MODE=password; return ;;
    esac
    printf '%s\n' 'Выбери 1, 2 или 3.' >&3
  done
  while true; do
    SSH_PUBLIC_KEY=$(read_prompt 'Вставь строку из файла .pub') || cancel
    SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY%$'\r'}
    if check_pubkey "$SSH_PUBLIC_KEY"; then return; fi
    printf '%s\n' 'Нужен публичный ключ OpenSSH.' >&3
  done
}

ask_port() {
  local title=$1 default_port=$2 value
  while true; do
    value=$(read_prompt "$title [$default_port]") || return 1
    value=${value:-$default_port}
    if [[ $value =~ ^[0-9]{1,5}$ ]] && (( 10#$value >= 1 && 10#$value <= 65535 )); then
      printf '%d' "$((10#$value))"
      return
    fi
    printf '%s\n' 'Укажи порт от 1 до 65535.' >&3
  done
}

ask_ssh_address() {
  local client_port address current_port
  IFS=' ' read -r SSH_CLIENT_IP client_port SSH_LOCAL_ADDR SSH_LOCAL_PORT <<< "${SSH_CONNECTION:-}"
  SSH_CLIENT_IP=${SSH_CLIENT_IP:-127.0.0.1}
  address=${SSH_LOCAL_ADDR:-$(hostname -I | awk '{print $1}')}
  current_port=${SSH_LOCAL_PORT:-$(sshd_ports 2>/dev/null | awk 'NR==1 {print}' || true)}
  while true; do
    SSH_HOST=$(read_prompt "IP или домен [$address]") || cancel
    SSH_HOST=${SSH_HOST:-$address}
    if [[ $SSH_HOST =~ ^[a-zA-Z0-9:][a-zA-Z0-9.:-]*$ && ( $SSH_HOST != *:* || $SSH_HOST == *:*:* ) ]]; then
      break
    fi
    printf '%s\n' 'Укажи IP или домен без порта.' >&3
  done
  SSH_PORT=$(ask_port 'Текущий порт SSH с компьютера' "${current_port:-22}") || cancel
}

ask_hostname() {
  while true; do
    SERVER_NAME=$(read_prompt 'Имя хоста [server]') || cancel
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

verify_admin_access() {
  local port=$1 reply
  rm -f -- "$WORK_DIR/ssh-confirmed"
  printf '\nПроверь вход и sudo в другом окне\n' >&3
  printf 'ssh -t %s %s@%s "sudo touch -- %s/ssh-confirmed"\n' \
    "$(ssh_arguments "$port")" "$ADMIN_USER" "$SSH_HOST" "$WORK_DIR" >&3
  while [[ ! -f $WORK_DIR/ssh-confirmed ]]; do
    printf 'Enter — проверить, q — откат. ' >&3
    IFS= read -r -t 300 reply <&3 || return 1
    [[ -z $reply ]] || return 1
    if [[ ! -f $WORK_DIR/ssh-confirmed ]]; then printf '%s\n' 'Вход ещё не подтверждён.' >&3; fi
  done
}

ask_stages() {
  local stage reply choice valid
  local -a available=() choices=()
  local -A picked=()
  for stage in "${EXTRA_ORDER[@]}"; do
    if [[ $stage == install_mui && $ARCH != amd64 ]]; then continue; fi
    available+=("$stage")
    choice=' '
    if selected "$stage"; then choice=x; fi
    printf ' %s [%s] %s\n' "${#available[@]}" "$choice" "${EXTRA_LABELS[$stage]}" >&3
  done
  while true; do
    reply=$(read_prompt 'Номера через пробел. Enter — текущий выбор, 0 — пропустить.') || cancel
    case "$reply" in
      '') return ;;
      0) STAGES=(); return ;;
    esac
    read -ra choices <<< "$reply"
    picked=()
    valid=1
    for choice in "${choices[@]}"; do
      if [[ ! $choice =~ ^[1-7]$ ]] || (( choice > ${#available[@]} )); then
        valid=0
        break
      fi
      picked[${available[choice-1]}]=x
    done
    if (( valid )) && [[ -n ${picked[*]:-} ]]; then
      STAGES=()
      for stage in "${!picked[@]}"; do STAGES[$stage]=on; done
      return
    fi
    printf '%s\n' 'Проверь номера этапов.' >&3
  done
}

check_plan() {
  local tool
  local -a needed=()
  if ! selected install_packages; then
    if selected install_shell; then needed+=(git curl zsh fzf mc); fi
    if selected install_python && [[ ! -x $ADMIN_HOME/.local/bin/uv ]]; then needed+=(pipx); fi
    if selected install_docker && ! docker_local compose version >/dev/null 2>&1; then needed+=(curl); fi
    if selected install_dry; then needed+=(curl python3); fi
    if selected install_xui || selected install_mui; then needed+=(curl openssl); fi
    if selected install_mui; then needed+=(git); fi
    for tool in "${needed[@]}"; do
      if ! command -v "$tool" >/dev/null; then
        printf 'Нужен %s. Выбери «Пакеты APT».\n' "$tool"
        return 1
      fi
    done
  fi
  if ! selected install_docker; then
    if { selected install_xui || selected install_mui || selected install_dry; } &&
       ! docker_local info >/dev/null 2>&1; then
      printf '%s\n' 'Выбери «Docker и Compose».'
      return 1
    fi
    if { selected install_xui || selected install_mui; } && ! docker_local compose version >/dev/null 2>&1; then
      printf '%s\n' 'Для панелей нужен Compose.'
      return 1
    fi
  fi
}

run_stages() {
  local stage
  for stage in "${EXTRA_ORDER[@]}"; do
    if selected "$stage"; then step "${EXTRA_LABELS[$stage]}" "$stage"; fi
  done
}

run_setup() {
  section '1/5 · Пароль root'
  ROOT_NEW_PASSWORD=$(prompt_password 'Новый пароль root') || cancel
  run_step 'Пароль root' change_root_password

  section '2/5 · Пользователь и SSH'
  ask_admin_user
  LINUX_PASSWORD=$(prompt_password "Пароль $ADMIN_USER для sudo") || cancel
  ask_auth
  ask_ssh_address
  run_step 'Пользователь и sudo' setup_admin_user
  run_step 'Доступ SSH' configure_ssh
  verify_admin_access "$SSH_PORT" || fail 'Вход не подтверждён. Откат SSH.'
  SSH_ACCESS_PENDING=0

  section '3/5 · Имя хоста'
  ask_hostname
  run_step 'Имя хоста' set_server_hostname

  section '4/5 · Порт SSH'
  local default_port=${SSH_LOCAL_PORT:-$SSH_PORT}
  if [[ $default_port == 22 ]]; then default_port=2233; fi
  SSH_NEW_PORT=$(ask_port 'Новый порт SSH' "$default_port") || cancel
  run_step 'Порт SSH' change_ssh_port
  if (( SSH_PORT_PENDING )); then
    verify_admin_access "$SSH_NEW_PORT" || fail 'Вход не подтверждён. Откат порта.'
    run_step 'Закрываю старый порт' finish_ssh_port
  fi

  section '5/5 · Компоненты'
  local problem
  STAGES=([install_packages]=on [install_shell]=on [install_python]=on [install_docker]=on [install_xui]=on)
  if [[ $ARCH == amd64 && -f /opt/m-ui/install.state ]]; then STAGES[install_mui]=on; fi
  if [[ -x /usr/local/bin/dry ]]; then STAGES[install_dry]=on; fi
  while true; do
    ask_stages
    if problem=$(check_plan); then break; fi
    printf '%s\n' "$problem" >&3
  done
  run_live "$LOG_FILE" run_stages
}

show_panel_password() {
  local panel=$1 answer
  if [[ -z $PANEL_PASSWORD ]]; then return; fi
  if command -v tput >/dev/null && tput smcup >&3 2>/dev/null; then PRIVATE_SCREEN=1; fi
  section "$panel · Доступ"
  printf 'URL     http://127.0.0.1:%s/%s/\nЛогин   %s\nПароль  %s\n' \
    "$PANEL_PORT" "$PANEL_PATH" "$PANEL_USER" "$PANEL_PASSWORD" >&3
  answer=$(read_prompt 'Enter — данные сохранены, q — позже') || answer=q
  close_private_screen
  if [[ -z $answer ]]; then acknowledge_panel_login "/opt/$panel"; fi
}

show_access_cards() {
  local panel ssh_args
  ssh_args=$(ssh_arguments "$SSH_PORT")
  section 'Готово'
  printf 'Хост  %s\nSSH   %s · порт %s\nssh %s %s@%s\n' \
    "$SERVER_NAME" "$ADMIN_USER" "$SSH_PORT" "$ssh_args" "$ADMIN_USER" "$SSH_HOST" >&3
  if selected install_shell; then printf '%s\n' 'Для Zsh открой новый сеанс.' >&3; fi
  for panel in 3x-ui m-ui; do
    if [[ " ${READY_PANELS[*]} " == *" $panel "* ]]; then
      load_panel_state "/opt/$panel"
      printf '%-7s  127.0.0.1:%s\n' "$panel" "$PANEL_PORT" >&3
    else
      printf '%-7s  пропущено\n' "$panel" >&3
    fi
  done
  for panel in "${READY_PANELS[@]}"; do
    load_panel_state "/opt/$panel"
    show_panel_password "$panel"
    printf '\n%s · Туннель с компьютера\n' "$panel" >&3
    printf 'ssh %s -o ExitOnForwardFailure=yes -N -L 127.0.0.1:%s:127.0.0.1:%s %s@%s\n' \
      "$ssh_args" "$PANEL_PORT" "$PANEL_PORT" "$ADMIN_USER" "$SSH_HOST" >&3
    printf 'URL     http://127.0.0.1:%s/%s/\nЛогин   %s\n' "$PANEL_PORT" "$PANEL_PATH" "$PANEL_USER" >&3
  done
  printf '\nЖурнал  %s\n' "$LOG_FILE" >&3
}

main() {
  local tool
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
  for tool in sudo ssh-keygen ss /usr/sbin/sshd; do
    command -v "$tool" >/dev/null || fail 'До запуска установи sudo, openssh-server и iproute2.'
  done
  getent group sudo >/dev/null || fail 'Нужна группа sudo.'
  [[ -f $SSHD_CONFIG && ! -L $SSHD_CONFIG ]] || fail 'Проверь /etc/ssh/sshd_config.'
  if ! systemctl is-active --quiet ssh.service && ! systemctl is-active --quiet ssh.socket; then
    fail 'Сначала запусти OpenSSH.'
  fi

  exec 3<>/dev/tty
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
  show_access_cards
  if (( KEY_EXPORT_READY )); then
    local answer
    answer=$(read_prompt 'Удалить копию SSH-ключа с сервера? [д/Н]') || answer=
    if [[ $answer == д || $answer == y ]]; then rm -rf -- "$KEY_EXPORT_DIR"; fi
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
