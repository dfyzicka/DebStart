# Host packages, SSH and the selected user's shell.

detect_platform() {
  local release_file=${1:-/etc/os-release}
  local ID= VERSION_ID= VERSION_CODENAME=
  [[ -r $release_file ]] || fail 'Не удалось определить версию системы.'
  source "$release_file"
  case "$ID:$VERSION_ID:$VERSION_CODENAME" in
    debian:12:bookworm|debian:13:trixie|ubuntu:22.04:jammy|ubuntu:24.04:noble|ubuntu:26.04:resolute) ;;
    *) fail 'Поддерживаются Debian 12/13 и Ubuntu 22.04/24.04/26.04 LTS.' ;;
  esac
  DISTRO_ID=$ID
  DISTRO_CODENAME=$VERSION_CODENAME
  DISTRO_LABEL="${ID^} $VERSION_ID"
}

apt_run() {
  printf '  apt-get'
  printf ' %q' "$@"
  printf '\n'
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold "$@"
}

update_apt_indexes() {
  apt_run update
  if [[ $DISTRO_ID == ubuntu ]] &&
     ! apt-cache policy | awk '/,c=universe,/ { found=1 } END { exit !found }'; then
    if ! command -v add-apt-repository >/dev/null; then
      apt_run install -y --no-install-recommends software-properties-common
    fi
    add-apt-repository --yes --no-update --component universe
    apt_run update
  fi
}

ensure_apt_indexes() {
  if (( ! APT_READY )); then
    update_apt_indexes
    APT_READY=1
  fi
}

host_packages() {
  local -a packages=(
    ca-certificates curl git sudo openssl openssh-server iproute2
    zip unzip nano fzf speedtest-cli fonts-powerline bat neovim
    ncdu bpytop mc duf fd-find zsh python3-full python3-pip pipx
  )
  case "$DISTRO_CODENAME" in
    jammy) packages+=(exa neofetch tldr) ;;
    bookworm) packages+=(exa neofetch nala tealdeer) ;;
    noble) packages+=(eza neofetch nala tealdeer) ;;
    trixie|resolute) packages+=(eza fastfetch nala tealdeer) ;;
  esac
  printf '%s\n' "${packages[@]}"
}

install_packages() {
  local -a packages
  ensure_apt_indexes
  mapfile -t packages < <(host_packages)
  apt_run install -y --no-install-recommends "${packages[@]}"

  # Some minimal images exclude /usr/share/doc via dpkg path filters.
  if ! fzf --zsh >/dev/null 2>&1 &&
     [[ ! -r /usr/share/doc/fzf/examples/completion.zsh || ! -r /usr/share/doc/fzf/examples/key-bindings.zsh ]]; then
    apt_run -o 'Dpkg::Options::=--path-include=/usr/share/doc/fzf/examples*' \
      install -y --reinstall fzf
    [[ -r /usr/share/doc/fzf/examples/completion.zsh && -r /usr/share/doc/fzf/examples/key-bindings.zsh ]] ||
      fail 'Не удалось восстановить Zsh-интеграцию fzf из пакета APT.'
  fi
}

set_server_hostname() {
  local hosts_temp
  hostnamectl set-hostname "$SERVER_NAME"
  hosts_temp=$(mktemp /etc/.hosts.debian-start.XXXXXXXX)
  awk -v name="$SERVER_NAME" '
    $1 == "127.0.1.1" && !updated {
      $2 = name
      updated = 1
    }
    { print }
    END { if (!updated) print "127.0.1.1\t" name }
  ' /etc/hosts > "$hosts_temp"
  chmod --reference=/etc/hosts "$hosts_temp"
  chown --reference=/etc/hosts "$hosts_temp"
  mv -T -- "$hosts_temp" /etc/hosts

  if command -v cloud-init >/dev/null && [[ -d /etc/cloud/cloud.cfg.d ]]; then
    printf 'preserve_hostname: true\n' > "$WORK_DIR/hostname.cfg"
    install -m 0644 "$WORK_DIR/hostname.cfg" /etc/cloud/cloud.cfg.d/99-debian-start-hostname.cfg
  fi
}

as_admin() {
  runuser -u "$ADMIN_USER" -- env \
    -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u PIPX_HOME -u PIPX_BIN_DIR \
    /bin/sh -c 'cd "$HOME" && exec "$@"' sh "$@"
}

check_pubkey() {
  local key=$1
  [[ $key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:blank:]]+[A-Za-z0-9+/=]+([[:blank:]].*)?$ ]] ||
    return 1
  printf '%s\n' "$key" > "$WORK_DIR/key.pub"
  ssh-keygen -l -f "$WORK_DIR/key.pub" >/dev/null 2>&1
}

generate_ssh_key() {
  local key_group answer
  KEY_EXPORT_DIR=$(mktemp -d /run/debian-start-key.XXXXXXXX)
  KEY_EXPORT_OWNER=${SUDO_USER:-root}
  key_group=$(id -g "$KEY_EXPORT_OWNER")

  printf '%s\n' 'Задай парольную фразу для ключа.' >&3
  while true; do
    ssh-keygen -q -t ed25519 -a 64 -C "$ADMIN_USER@$SSH_HOST" \
      -f "$KEY_EXPORT_DIR/id_ed25519" <&3 >&3 2>&3
    if ! ssh-keygen -y -P '' -f "$KEY_EXPORT_DIR/id_ed25519" </dev/null >/dev/null 2>&1; then
      break
    fi
    rm -f -- "$KEY_EXPORT_DIR/id_ed25519" "$KEY_EXPORT_DIR/id_ed25519.pub"
    printf '%s\n' 'Введи непустую парольную фразу.' >&3
  done

  install -m 0600 "$KEY_EXPORT_DIR/id_ed25519.pub" "$WORK_DIR/key.pub"
  chmod 0600 "$KEY_EXPORT_DIR/id_ed25519"
  chown "$KEY_EXPORT_OWNER:$key_group" "$KEY_EXPORT_DIR/id_ed25519" "$KEY_EXPORT_DIR"
  printf '\nСкачай ключ в другом окне\n' >&3
  print_key_copy >&3
  answer=$(read_prompt 'Enter — ключ скачан, q — выйти') || cancel
  [[ -z $answer ]] || cancel
  KEY_EXPORT_READY=1
}

setup_admin_user() {
  if ! getent passwd "$ADMIN_USER" >/dev/null; then
    useradd --create-home --user-group --shell /bin/bash "$ADMIN_USER"
  fi
  usermod -aG sudo "$ADMIN_USER"
  ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  printf '%s:%s\n' "$ADMIN_USER" "$LINUX_PASSWORD" | chpasswd
  unset LINUX_PASSWORD
}

install_authorized_key() {
  if [[ $AUTH_MODE == generate ]]; then
    generate_ssh_key
  else
    check_pubkey "$SSH_PUBLIC_KEY" || fail 'Проверь формат публичного SSH-ключа.'
  fi
  as_admin /bin/sh -eu -c '
    umask 077
    mkdir -p .ssh
    chmod 0700 .ssh
    touch .ssh/authorized_keys
    chmod 0600 .ssh/authorized_keys
    IFS= read -r key
    if ! grep -Fqx -- "$key" .ssh/authorized_keys; then
      if [ -s .ssh/authorized_keys ] && [ "$(tail -c 1 .ssh/authorized_keys | wc -l)" -eq 0 ]; then
        printf "\n" >> .ssh/authorized_keys
      fi
      printf "%s\n" "$key" >> .ssh/authorized_keys
    fi
  ' < "$WORK_DIR/key.pub"
}

change_root_password() {
  local status=0
  printf 'root:%s\n' "$ROOT_NEW_PASSWORD" | chpasswd || status=$?
  unset ROOT_NEW_PASSWORD
  return "$status"
}

clone_shell_component() {
  local repository=$1 directory=$2 check_file=$3
  as_admin bash -eu -c '
    if [[ -f $2/$3 ]]; then exit 0; fi
    [[ ! -e $2 ]] || { printf "Проверь существующий каталог %s\n" "$2" >&2; exit 1; }
    mkdir -p -- "$(dirname -- "$2")"
    stage=$(mktemp -d "${2}.XXXXXXXX")
    trap '\''rm -rf -- "$stage"'\'' EXIT
    git clone --depth 1 "$1" "$stage"
    mv -T -- "$stage" "$2"
  ' bash "$repository" "$directory" "$check_file"
}

install_profile_file() {
  local src=$1 dst=$2
  as_admin bash -eu -c '
    umask 077
    mkdir -p -- "$(dirname -- "$1")"
    if [[ -e $1 && ! -e $1.before-debian-start ]]; then
      cp -a -- "$1" "$1.before-debian-start"
    fi
    stage=$(mktemp "${1}.XXXXXXXX")
    trap '\''rm -f -- "$stage"'\'' EXIT
    cat > "$stage"
    mv -T -- "$stage" "$1"
  ' bash "$dst" < "$src"
}

install_shell() {
  local skin
  clone_shell_component https://github.com/ohmyzsh/ohmyzsh.git .oh-my-zsh oh-my-zsh.sh
  clone_shell_component https://github.com/romkatv/powerlevel10k.git \
    .oh-my-zsh/custom/themes/powerlevel10k powerlevel10k.zsh-theme
  clone_shell_component https://github.com/zsh-users/zsh-autosuggestions.git \
    .oh-my-zsh/custom/plugins/zsh-autosuggestions zsh-autosuggestions.plugin.zsh
  clone_shell_component https://github.com/zsh-users/zsh-syntax-highlighting.git \
    .oh-my-zsh/custom/plugins/zsh-syntax-highlighting zsh-syntax-highlighting.plugin.zsh

  if ! as_admin test -e .local/state/debian-start/profile-v1; then
    printf '%s\n' 'Копирую конфигурацию Zsh и скины Midnight Commander.'
    curl --fail --silent --show-error --location --proto '=https' --retry 3 --max-time 30 \
      'https://gist.githubusercontent.com/Ajnasz/8685681/raw/d3c00b3aa74fa126050babc3ed7ef4dca33b7049/ajnasz-blue.ini' \
      -o "$WORK_DIR/ajnasz-blue.ini"
    grep -Fq 'Ajnasz Blue Theme' "$WORK_DIR/ajnasz-blue.ini" ||
      fail 'Не удалось проверить скин Ajnasz Blue.'
    install_profile_file "$INSTALLER_DIR/profile/zshrc" .zshrc
    install_profile_file "$INSTALLER_DIR/profile/p10k.zsh" .p10k.zsh
    install_profile_file "$INSTALLER_DIR/profile/nanorc" .nanorc
    for skin in dracula.ini dracula256.ini; do
      install_profile_file "$INSTALLER_DIR/profile/mc/skins/$skin" ".local/share/mc/skins/$skin"
    done
    install_profile_file "$WORK_DIR/ajnasz-blue.ini" .local/share/mc/skins/ajnasz-blue.ini
    as_admin bash -eu -c '
      file=.config/mc/ini
      mkdir -p .config/mc .local/state/debian-start
      if [[ -e $file && ! -e $file.before-debian-start ]]; then
        cp -a -- "$file" "$file.before-debian-start"
      fi
      if [[ -f $file ]] && grep -q "^\[Midnight-Commander\]" "$file"; then
        sed -i "/^\[Midnight-Commander\]/,/^\[/s/^skin=.*/skin=dracula256/" "$file"
        if ! sed -n "/^\[Midnight-Commander\]/,/^\[/p" "$file" | grep -q "^skin="; then
          sed -i "/^\[Midnight-Commander\]/a skin=dracula256" "$file"
        fi
      else
        printf "\n[Midnight-Commander]\nskin=dracula256\n" >> "$file"
      fi
      zsh -n .zshrc
      zsh -n .p10k.zsh
    '
  else
    if ! as_admin test -e .zshrc; then install_profile_file "$INSTALLER_DIR/profile/zshrc" .zshrc; fi
    if ! as_admin test -e .p10k.zsh; then install_profile_file "$INSTALLER_DIR/profile/p10k.zsh" .p10k.zsh; fi
  fi
  if ! as_admin env -u ZDOTDIR TERM=xterm-256color timeout 20s zsh -lic \
      '(( $+functions[omz] && $+functions[p10k] ))' </dev/null; then
    fail "Oh My Zsh или Powerlevel10k не загрузились под $ADMIN_USER. Проверь .zshrc и ZDOTDIR этой учётки."
  fi
  usermod -s "$(command -v zsh)" "$ADMIN_USER"
  as_admin touch .local/state/debian-start/profile-v1
  printf 'Oh My Zsh и Powerlevel10k загрузились под %s.\n' "$ADMIN_USER"
}

install_python() {
  local uv="$ADMIN_HOME/.local/bin/uv" version
  if [[ ! -x $uv ]]; then
    as_admin pipx install uv
  fi
  as_admin "$uv" python install "$PYTHON_VERSION" --default
  version=$(as_admin "$ADMIN_HOME/.local/bin/python3" --version)
  [[ $version == "Python $PYTHON_VERSION" ]] ||
    fail "В профиле $ADMIN_USER команда python3 выдаёт $version."
  printf '%s\n' "$version"
}
