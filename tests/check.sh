#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
for script in bootstrap.sh installer/lib/*.sh tests/check.sh; do
  bash -n "$script"
done
zsh -n installer/profile/zshrc
zsh -n installer/profile/p10k.zsh
bash bootstrap.sh --help >/dev/null

source ./bootstrap.sh
ARCH=amd64

state_dir=$(mktemp -d)
trap 'rm -rf -- "$state_dir"' EXIT
(
  exec 3>"$state_dir/menu"
  read_prompt() {
    if [[ $1 == 'Какие этапы пропустить?' ]]; then
      printf '%s' "$fixture_skips"
    else
      printf '%s' 'д'
    fi
  }
  check_plan() { :; }
  fixture_skips='1-12'
  ask_stages
  [[ -z ${STAGES[*]:-} ]]
  fixture_skips=''
  ask_stages
  [[ ${#STAGES[@]} == 12 ]]
  selected install_mui
  selected install_dry
  fixture_skips='1 3 7'
  ask_stages
  [[ ${#STAGES[@]} == 9 ]]
  selected setup_admin_user
  if selected change_root_password || selected configure_ssh || selected install_shell; then exit 1; fi
  fixture_skips='1–3 7'
  ask_stages
  [[ ${#STAGES[@]} == 8 ]]
  if selected change_root_password || selected setup_admin_user || selected configure_ssh || selected install_shell; then exit 1; fi
  selected install_packages
  grep -Fq 'Пропустить · Пароль root' "$state_dir/menu"
  grep -Fq 'Запустить  · Пакеты APT' "$state_dir/menu"
  ARCH=arm64
  fixture_skips='1-10'
  ask_stages
  [[ ${#STAGES[@]} == 1 ]]
  selected install_dry
  for invalid in '0' '3-1' '1 3-99' '2-'; do
    if apply_skipped_stages "$invalid" first second third; then exit 1; fi
    [[ ${#STAGES[@]} == 1 ]]
    selected install_dry
  done
)

# The wrapper retries APT lock contention and returns other failures.
(
  WORK_DIR=$state_dir
  apt-get() {
    [[ $* == *'Dpkg::Use-Pty=0'* ]] || return 70
    if IFS= read -r input; then return 70; fi
    if [[ -e $WORK_DIR/apt-retried ]]; then return 0; fi
    case "$fixture_apt" in
      lists)
        printf '%s\n' \
          'E: Could not get lock /var/lib/apt/lists/lock. It is held by process 7340 (apt-get)' \
          'E: Unable to lock directory /var/lib/apt/lists/' >&2 ;;
      dpkg)
        printf '%s\n' \
          'Error: Could not get lock /var/lib/dpkg/lock-frontend - open (11: Resource temporarily unavailable)' \
          'Error: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?' >&2 ;;
      denied)
        printf '%s\n' 'E: Could not open lock file /var/lib/apt/lists/lock - open (13: Permission denied)' >&2 ;;
    esac
    return 100
  }
  sleep() {
    [[ $1 == 5 ]]
    touch "$WORK_DIR/apt-retried"
  }
  for fixture_apt in lists dpkg; do
    rm -f -- "$WORK_DIR/apt-retried"
    apt_run update <<< 'terminal input' > "$WORK_DIR/apt-test"
    [[ -f $WORK_DIR/apt-retried ]]
    grep -Fq 'APT занят' "$WORK_DIR/apt-test"
  done
  rm -f -- "$WORK_DIR/apt-retried"
  fixture_apt=denied
  status=0
  apt_run update > "$WORK_DIR/apt-test" || status=$?
  [[ $status == 100 && ! -e $WORK_DIR/apt-retried ]]
)

while read -r fixture_id fixture_version fixture_codename fixture_ls fixture_tldr; do
  printf 'ID=%s\nVERSION_ID=%s\nVERSION_CODENAME=%s\n' \
    "$fixture_id" "$fixture_version" "$fixture_codename" > "$state_dir/os-release"
  detect_platform "$state_dir/os-release"
  [[ $DISTRO_ID == "$fixture_id" && $DISTRO_CODENAME == "$fixture_codename" ]]
  packages=$(host_packages)
  grep -Fxq "$fixture_ls" <<< "$packages"
  grep -Fxq "$fixture_tldr" <<< "$packages"
done <<'PLATFORMS'
debian 12 bookworm exa tealdeer
debian 13 trixie eza tealdeer
ubuntu 22.04 jammy exa tldr
ubuntu 24.04 noble eza tealdeer
ubuntu 26.04 resolute eza tealdeer
PLATFORMS

fixture_password='x'
chpasswd() {
  [[ $# == 0 ]]
  cat > "$state_dir/password-stdin"
}
(
  exec 3>"$state_dir/terminal"
  ROOT_NEW_PASSWORD=$fixture_password
  run_live "$state_dir/live.log" step 'Пароль root' change_root_password
  [[ ! -v ROOT_NEW_PASSWORD ]]
)
cmp "$state_dir/terminal" "$state_dir/live.log"
grep -Fq '✓ Пароль root' "$state_dir/live.log"
! grep -Fq "root:$fixture_password" "$state_dir/live.log"
[[ $(< "$state_dir/password-stdin") == "root:$fixture_password" ]]

# Check selected steps execute in order and a port-only run asks for no passwords.
(
  exec 3>"$state_dir/setup-ui"
  prompt_password() { printf 'x'; }
  ask_admin_user() { ADMIN_USER=ops; }
  ask_auth() { AUTH_MODE=password; }
  detect_ssh_context() { SSH_PORT=22 SSH_LOCAL_PORT=22 SSH_LOGIN=root; }
  ask_hostname() { SERVER_NAME=server; }
  ask_port() { printf '2233'; }
  ask_stages() {
    if [[ $fixture_selection == port ]]; then STAGES=([change_ssh_port]=on)
    else
      STAGES=([change_root_password]=on [setup_admin_user]=on [configure_ssh]=on
              [set_server_hostname]=on [change_ssh_port]=on [install_packages]=on [install_shell]=on)
    fi
  }
  run_live() { shift; "$@"; }
  trace() { printf '%s\n' "$1" >> "$state_dir/order"; }
  change_root_password() { trace root; }
  setup_admin_user() { trace user; }
  configure_ssh() { trace access; }
  set_server_hostname() { [[ $SSH_ACCESS_PENDING == 0 ]]; trace hostname; }
  change_ssh_port() { [[ $SSH_NEW_PORT == 2233 && $SSH_PORT == 22 ]]; SSH_PORT=2233; trace port; }
  install_packages() { [[ $SSH_PORT_PENDING == 0 ]]; trace packages; }
  install_shell() { trace shell; }
  fixture_selection=all
  run_setup > "$state_dir/setup-output"
  diff -u <(printf '%s\n' root user access hostname port packages shell) "$state_dir/order"
  : > "$state_dir/order"
  fixture_selection=port
  prompt_password() { trace password-prompt; printf 'x'; }
  ask_admin_user() { trace user-prompt; ADMIN_USER=ops; }
  run_setup > "$state_dir/setup-output"
  [[ $(< "$state_dir/order") == port && $SSH_PORT == 2233 ]]
)

cat > "$state_dir/sshd-before" <<'CONFIG'
Port 22
ALLOWUSERS old
PermitRootLogin=yes
UsePAM yes
Match User legacy
    AllowUsers legacy
    PasswordAuthentication yes
CONFIG
sshd_body access "$state_dir/sshd-before" > "$state_dir/sshd-access"
sshd_body port "$state_dir/sshd-access" > "$state_dir/sshd-port"
grep -Fxq 'Port 22' "$state_dir/sshd-access"
grep -Fxq 'UsePAM yes' "$state_dir/sshd-port"
! grep -iEq 'allowusers|permitrootlogin|passwordauthentication|^port ' "$state_dir/sshd-port"

# Match the requested local port even when ss returns unrelated listeners.
(
  ss() { printf '%s\n' 'LISTEN 0 128 127.0.0.1:22 0.0.0.0:*' 'LISTEN 0 128 127.0.0.1:2222 0.0.0.0:*'; }
  ssh_listening 22
  if ssh_listening 2233; then exit 1; fi
  [[ $(ssh_listener_rows 22) == 'LISTEN 0 128 127.0.0.1:22 0.0.0.0:*' ]]
)

# Check a port change preserves socket binding addresses in both phases.
(
  WORK_DIR=$state_dir
  SSH_SOCKET_ACTIVE=1
  SSH_SOCKET_ENDPOINTS=('127.0.0.1:22' '[::]:22')
  SSH_NEW_PORT=2233
  install() { [[ $1 == -m && $3 == "$WORK_DIR/ssh-socket.conf" && $4 == "$SSH_SOCKET_CONFIG" ]]; }
  write_ssh_socket both
  grep -Fxq 'ListenStream=127.0.0.1:22' "$WORK_DIR/ssh-socket.conf"
  grep -Fxq 'ListenStream=[::]:2233' "$WORK_DIR/ssh-socket.conf"
  write_ssh_socket new
  grep -Fxq 'ListenStream=127.0.0.1:2233' "$WORK_DIR/ssh-socket.conf"
  ! grep -q ':22$' "$WORK_DIR/ssh-socket.conf"
)

# Exercise profile paths from the archive layout without contacting upstream.
(
  WORK_DIR=$state_dir
  ADMIN_USER=fixture
  fixture_home="$state_dir/admin"
  mkdir "$fixture_home"
  clone_shell_component() { :; }
  curl() { printf '%s\n' '# Ajnasz Blue Theme' > "${!#}"; }
  as_admin() (
    cd -- "$fixture_home"
    if [[ $1 == env ]]; then
      [[ $* == *'functions[omz]'* && $* == *'functions[p10k]'* ]]
      return
    fi
    "$@"
  )
  usermod() { [[ $1 == -s && $3 == "$ADMIN_USER" ]]; }
  install_shell
  cmp installer/profile/mc/skins/dracula.ini "$fixture_home/.local/share/mc/skins/dracula.ini"
  cmp installer/profile/mc/skins/dracula256.ini "$fixture_home/.local/share/mc/skins/dracula256.ini"
  grep -Fxq 'skin=dracula256' "$fixture_home/.config/mc/ini"
)

(
  STAGES=([install_xui]=on)
  WORK_DIR=$state_dir
  READY_PANELS=(3x-ui)
  SERVER_NAME=server ADMIN_USER=ops SSH_LOGIN=ops AUTH_MODE=password SSH_PORT=2233 SSH_HOST=203.0.113.10
  load_panel_state() {
    [[ $1 == /opt/3x-ui ]]
    PANEL_PORT=2081 PANEL_PATH=1122334455667788 PANEL_USER=panel11223344 PANEL_PASSWORD=fixture-private
  }
  show_panel_password() { [[ $1 == 3x-ui && $PANEL_PASSWORD == fixture-private ]]; }
  exec 3>"$state_dir/cards"
  show_access_cards
  grep -Fq '127.0.0.1:2081' "$state_dir/cards"
  grep -Fq 'm-ui     пропущено' "$state_dir/cards"
  grep -Fq '127.0.0.1:2081:127.0.0.1:2081 ops@203.0.113.10' "$state_dir/cards"
  ! grep -Fq fixture-private "$state_dir/cards"
)

printf '%s\n' 2054 1122334455667788 panel11223344 00000000000000000000000000000000 \
  > "$state_dir/install.state"
load_panel_state "$state_dir"
[[ ${#PANEL_PASSWORD} == 32 ]]
acknowledge_panel_login "$state_dir"
load_panel_state "$state_dir"
[[ -z $PANEL_PASSWORD && $PANEL_PORT == 2054 && $PANEL_PATH == 1122334455667788 ]]

printf '%s\n' 'Проверки DebStart прошли.'
