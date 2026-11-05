#!/usr/bin/env bash
set +x
set -Eeuo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C.UTF-8
umask 077

INSTALLER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/installer" && pwd -P)
readonly INSTALLER_DIR
readonly PYTHON_VERSION=3.15.2 DRY_VERSION=v0.13.0
readonly LOG_FILE=/var/log/debian-start.log
WORK_DIR=
KEY_EXPORT_DIR=
KEY_EXPORT_READY=0
DIALOG_READY=0
CURRENT_STAGE='Подготовка мастера'
READY_PANELS=()

source "$INSTALLER_DIR/lib/system.sh"
source "$INSTALLER_DIR/lib/panels.sh"

ui() {
  dialog --backtitle 'DEBIAN START  /  Настройка сервера' \
    --title "$CURRENT_STAGE" --ok-label 'Далее' --cancel-label 'Отмена' \
    --yes-label 'Да' --no-label 'Нет' "$@" 2>&1 1>&3 <&3
}

fail() {
  printf '%s\n' "$1" >&2
  if (( DIALOG_READY )); then
    ui --msgbox "$1\n\nЖурнал  $LOG_FILE" 11 73 || true
  fi
  exit 1
}

on_error() {
  local status=$1
  trap - ERR
  if (( BASH_SUBSHELL == 0 )); then
    local message="Ошибка на шаге «$CURRENT_STAGE» (код $status).\n\nЖурнал  $LOG_FILE"
    if (( KEY_EXPORT_READY )); then
      message+="\nВременный ключ  $KEY_EXPORT_DIR"
    fi
    printf '%b\n' "$message" >&2
    if (( DIALOG_READY )); then
      ui --msgbox "$message" 11 73 || true
    fi
  fi
  exit "$status"
}

cleanup() {
  if [[ -n $KEY_EXPORT_DIR && $KEY_EXPORT_READY == 0 ]]; then
    rm -rf -- "$KEY_EXPORT_DIR"
  fi
  if [[ -n $WORK_DIR ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}

cancel() {
  printf '\nМастер закрыт.\n' >&3
  exit 0
}

step() {
  CURRENT_STAGE=$1
  shift
  ui --infobox "Выполняется этап «$CURRENT_STAGE».\n\nЖурнал  $LOG_FILE" 8 73
  printf '\n[%s] %s\n' "$(date -Is)" "$CURRENT_STAGE" >> "$LOG_FILE"
  "$@" >> "$LOG_FILE" 2>&1
}

ask_identity() {
  local default_hostname account_uid
  default_hostname=$(hostname -s)
  while true; do
    SERVER_NAME=$(ui --inputbox 'Короткое имя сервера, например beerver.' 8 73 "$default_hostname") || cancel
    if [[ $SERVER_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
      SERVER_NAME=${SERVER_NAME,,}
      break
    fi
    ui --msgbox 'Имя должно содержать 1–63 латинские буквы, цифры или дефисы.' 8 73 || cancel
  done
  while true; do
    ADMIN_USER=$(ui --inputbox 'Логин пользователя для SSH и sudo.' 8 73 'ops') || cancel
    if [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $ADMIN_USER != root ]]; then
      account_uid=$(id -u "$ADMIN_USER" 2>/dev/null || true)
      if [[ -z $account_uid || $account_uid -ge 1000 && $account_uid -ne 65534 ]]; then
        break
      fi
    fi
    ui --msgbox 'Введи обычный логин Linux. Используй строчные латинские буквы, цифры, дефис и подчёркивание.' 8 73 || cancel
  done
}

prompt_password() {
  local label=$1 password confirmation
  while true; do
    password=$(ui --passwordbox "$label. Минимум 12 символов." 8 73) || return 1
    confirmation=$(ui --passwordbox 'Повтори пароль.' 8 73) || return 1
    if [[ ${#password} -ge 12 && $password == "$confirmation" ]]; then
      printf '%s' "$password"
      return
    fi
    ui --msgbox 'Проверь длину пароля и повторный ввод.' 8 73 || return 1
  done
}

ask_auth() {
  AUTH_MODE=$(ui --default-item key --menu 'Как входить на сервер по SSH?' 13 73 3 \
    key 'Вставить свой публичный ключ' \
    generate 'Создать новый Ed25519 и забрать его по SCP' \
    password 'Вход по паролю для этой учётки') || cancel
  SSH_PUBLIC_KEY=
  LINUX_PASSWORD=
  if [[ $AUTH_MODE == key ]]; then
    while true; do
      SSH_PUBLIC_KEY=$(ui --inputbox 'Вставь содержимое файла .pub одной строкой.' 9 73) || cancel
      SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY%$'\r'}
      if [[ -n $SSH_PUBLIC_KEY ]] && { ! command -v ssh-keygen >/dev/null || check_pubkey "$SSH_PUBLIC_KEY"; }; then
        break
      fi
      ui --msgbox 'Нужен корректный публичный ключ OpenSSH.' 8 73 || cancel
    done
  fi
  if [[ $AUTH_MODE == password ]] || ! getent passwd "$ADMIN_USER" >/dev/null; then
    LINUX_PASSWORD=$(prompt_password "Пароль Linux для $ADMIN_USER") || cancel
  fi
}

ask_root_password() {
  unset ROOT_NEW_PASSWORD
  CHANGE_ROOT_PASSWORD=0
  if ui --defaultno --yes-label 'Задать' --no-label 'Пропустить' --yesno \
    'Задать новый пароль root?\n\nЭто активирует системный пароль root. Возможность входа по SSH определяет конфигурация sshd.' 10 73; then
    ROOT_NEW_PASSWORD=$(prompt_password 'Новый пароль root') || cancel
    CHANGE_ROOT_PASSWORD=1
  elif [[ $? != 1 ]]; then
    cancel
  fi
}

ask_ssh_address() {
  local client_ip client_port local_ip local_port address
  IFS=' ' read -r client_ip client_port local_ip local_port <<< "${SSH_CONNECTION:-}"
  SSH_CLIENT_IP=${client_ip:-127.0.0.1}
  address=${local_ip:-$(hostname -I | awk '{print $1}')}
  local_port=${local_port:-$(/usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" && !seen++ { print $2 }' || true)}
  while true; do
    SSH_HOST=$(ui --inputbox 'IP или домен, по которому твой компьютер подключается к серверу.' \
      9 73 "$address") || cancel
    if [[ $SSH_HOST =~ ^[a-zA-Z0-9:][a-zA-Z0-9.:-]*$ && ( $SSH_HOST != *:* || $SSH_HOST == *:*:* ) ]]; then
      break
    fi
    ui --msgbox 'Введи адрес сервера без схемы, порта и квадратных скобок.' 8 73 || cancel
  done
  while true; do
    SSH_PORT=$(ui --inputbox 'Внешний порт SSH для команды подключения.' 8 73 "${local_port:-22}") || cancel
    if [[ $SSH_PORT =~ ^[0-9]{1,5}$ ]] && (( 10#$SSH_PORT >= 1 && 10#$SSH_PORT <= 65535 )); then
      SSH_PORT=$((10#$SSH_PORT))
      break
    fi
    ui --msgbox 'Номер порта должен быть от 1 до 65535.' 8 73 || cancel
  done
}

ask_modules() {
  local selection choice mui_default=off dry_default=off
  local -a items=(3x-ui 'Панель Xray по SSH-туннелю' on)
  if [[ $ARCH == amd64 ]]; then
    if [[ -f /opt/m-ui/install.state ]]; then mui_default=on; fi
    items+=(m-ui 'Панель Mihomo для Mieru и Sudoku' "$mui_default")
  fi
  if [[ -x /usr/local/bin/dry ]]; then dry_default=on; fi
  items+=(dry 'Менеджер Docker в терминале' "$dry_default")
  selection=$(ui --separate-output --checklist 'Пробел переключает пункт. Enter подтверждает выбор.' \
    13 73 3 "${items[@]}") || cancel
  INSTALL_XUI=0
  INSTALL_MUI=0
  INSTALL_DRY=0
  while IFS= read -r choice; do
    case "$choice" in
      3x-ui) INSTALL_XUI=1 ;;
      m-ui) INSTALL_MUI=1 ;;
      dry) INSTALL_DRY=1 ;;
    esac
  done <<< "$selection"
  MODULE_LIST=${selection//$'\n'/, }
  MODULE_LIST=${MODULE_LIST:-Базовая настройка}
}

collect_plan() {
  local auth_label action root_action
  while true; do
    CURRENT_STAGE='Пользователь и сервер'
    ask_identity
    CURRENT_STAGE='Вход по SSH'
    ask_auth
    ask_ssh_address
    CURRENT_STAGE='Пароль root'
    ask_root_password
    CURRENT_STAGE='Компоненты'
    ask_modules
    case "$AUTH_MODE" in
      key) auth_label='Готовый публичный ключ' ;;
      generate) auth_label='Новый Ed25519' ;;
      password) auth_label='Пароль Linux' ;;
    esac
    action='Создать'
    if getent passwd "$ADMIN_USER" >/dev/null; then action='Настроить существующего'; fi
    root_action='Пропустить'
    if (( CHANGE_ROOT_PASSWORD )); then root_action='Задать новый'; fi
    CURRENT_STAGE='План установки'
    if ui --yes-label 'Установить' --no-label 'Изменить' --yesno \
      "Сервер  $SERVER_NAME\n$action пользователя  $ADMIN_USER\nSSH  $auth_label\nПароль root  $root_action\nDocker · Zsh · Oh My Zsh · MC · Python $PYTHON_VERSION\nКомпоненты  $MODULE_LIST" 15 73; then
      return
    elif [[ $? != 1 ]]; then
      cancel
    fi
    unset LINUX_PASSWORD ROOT_NEW_PASSWORD
  done
}

print_access_card() {
  local panel key_name ssh_args scp_host
  ssh_args="-p $SSH_PORT"
  if [[ $AUTH_MODE == password ]]; then
    ssh_args+=' -o PreferredAuthentications=password'
  fi
  printf 'DEBIAN START  /  УСТАНОВКА ЗАВЕРШЕНА\n'
  printf '\nСервер    %s\nУчётка    %s\nPython    %s\n' "$SERVER_NAME" "$ADMIN_USER" "$PYTHON_VERSION"
  printf 'Профиль   Zsh, Oh My Zsh, Powerlevel10k, fzf, MC Dracula256\nDocker    запущен\n'
  if (( CHANGE_ROOT_PASSWORD )); then printf 'Пароль root обновлён\n'; fi
  if (( INSTALL_DRY )); then printf 'dry       sudo dry\n'; fi

  if (( KEY_EXPORT_READY )); then
    key_name="$SERVER_NAME-$ADMIN_USER-ed25519"
    scp_host=$SSH_HOST
    if [[ $scp_host == *:* ]]; then scp_host="[$scp_host]"; fi
    printf '\nСкачай приватный ключ на свой компьютер через прежний вход\n'
    printf 'scp -P %s "%s@%s:%s/id_ed25519" "./%s"\n' \
      "$SSH_PORT" "$KEY_EXPORT_OWNER" "$scp_host" "$KEY_EXPORT_DIR" "$key_name"
    ssh_args+=" -i ./$key_name -o IdentitiesOnly=yes"
  fi
  printf '\nВход с твоего компьютера\nssh %s %s@%s\n' "$ssh_args" "$ADMIN_USER" "$SSH_HOST"

  for panel in "${READY_PANELS[@]}"; do
    load_panel_state "/opt/$panel"
    printf '\n%s  /  СТРАНИЦА ВХОДА ОТВЕЧАЕТ\n' "$panel"
    printf 'ssh %s -o ExitOnForwardFailure=yes -N -L %s:127.0.0.1:%s %s@%s\n' \
      "$ssh_args" "$PANEL_PORT" "$PANEL_PORT" "$ADMIN_USER" "$SSH_HOST"
    printf 'URL       http://127.0.0.1:%s/%s/\n' "$PANEL_PORT" "$PANEL_PATH"
    printf 'Логин     %s\n' "$PANEL_USER"
    if [[ -n $PANEL_PASSWORD ]]; then printf 'Пароль    %s\n' "$PANEL_PASSWORD"; fi
  done
  printf '\nЖурнал    %s\n' "$LOG_FILE"
}

main() {
  local apt_updated=0 panel
  if [[ ${1:-} == --help ]]; then
    printf '%s\n' 'Debian Start — установщик для Debian 12/13 и Ubuntu 22.04/24.04/26.04 LTS.' \
      'Запуск в терминале  sudo bash bootstrap.sh'
    return
  fi
  [[ $# -eq 0 ]] || fail 'Поддерживается только аргумент --help.'
  (( EUID == 0 )) || fail 'Запусти мастер через sudo bash bootstrap.sh.'
  [[ -t 0 && -t 1 ]] || fail 'Нужен интерактивный терминал. При SSH-запуске используй ssh -t.'
  detect_platform
  [[ -d /run/systemd/system ]] || fail 'Нужен сервер или ВМ с запущенным systemd.'
  ARCH=$(dpkg --print-architecture)
  [[ $ARCH == amd64 || $ARCH == arm64 ]] || fail 'Поддерживаемые архитектуры — amd64 и arm64.'

  exec 3<>/dev/tty
  exec 8>/run/debian-start.lock
  flock -n 8 || fail 'Другой экземпляр Debian Start уже запущен.'
  [[ ! -L $LOG_FILE ]] || fail "Проверь путь журнала $LOG_FILE."
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  WORK_DIR=$(mktemp -d /run/debian-start.XXXXXXXX)
  trap cleanup EXIT
  trap 'on_error $?' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! command -v dialog >/dev/null; then
    printf 'DEBIAN START  /  Подготовка терминального мастера\n' >&3
    update_apt_indexes >> "$LOG_FILE" 2>&1
    apt_updated=1
    apt_run install -y --no-install-recommends dialog >> "$LOG_FILE" 2>&1
  fi
  DIALOG_READY=1
  ui --msgbox "$DISTRO_LABEL · $ARCH\n\nСоберём пользователя, рабочую оболочку, Python и выбранные компоненты Docker." 10 73 || cancel
  collect_plan

  if (( ! apt_updated )); then step 'Обновление индекса APT' update_apt_indexes; fi
  step 'Установка системных пакетов' install_packages
  step 'Имя сервера' set_server_hostname
  step 'Настройка пользователя' setup_admin_user
  step 'Проверка и применение конфигурации SSH' configure_ssh
  step 'Oh My Zsh, Powerlevel10k и скины MC' install_shell
  step "Установка Python $PYTHON_VERSION" install_python
  step 'Docker Engine и Compose' install_docker
  if (( INSTALL_DRY )); then step "dry $DRY_VERSION" install_dry; fi
  if (( INSTALL_XUI )); then step 'Запуск 3x-ui' install_xui; fi
  if (( INSTALL_MUI )); then step 'Сборка и запуск m-ui' install_mui; fi
  if (( CHANGE_ROOT_PASSWORD )); then step 'Смена пароля root' change_root_password; fi

  CURRENT_STAGE='Данные для входа'
  print_access_card > "$WORK_DIR/access.txt"
  if ui --exit-label 'Данные сохранены' --textbox "$WORK_DIR/access.txt" 21 76; then
    for panel in "${READY_PANELS[@]}"; do acknowledge_panel_login "/opt/$panel"; done
  fi
  if (( KEY_EXPORT_READY )) && ui --defaultno --yesno \
    'Уже скачал ключ и проверил вход в отдельном окне SSH? Да удалит временную копию ключа на сервере.' 9 73; then
    rm -rf -- "$KEY_EXPORT_DIR"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
