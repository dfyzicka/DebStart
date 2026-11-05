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

# Feed dialog's output without installing packages or changing the host.
ui() { printf '%s' "$fixture_selection"; }
fixture_selection=
ask_modules
[[ $INSTALL_XUI == 0 && $INSTALL_MUI == 0 && $INSTALL_DRY == 0 ]]
fixture_selection=$'m-ui\ndry'
ask_modules
[[ $INSTALL_XUI == 0 && $INSTALL_MUI == 1 && $INSTALL_DRY == 1 ]]

state_dir=$(mktemp -d)
trap 'rm -rf -- "$state_dir"' EXIT

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

ui() {
  case "$1" in
    --defaultno) return "$fixture_root_choice" ;;
    --passwordbox) printf '%s' "$fixture_password" ;;
    *) return 1 ;;
  esac
}
fixture_root_choice=1
ROOT_NEW_PASSWORD=stale-fixture
ask_root_password
[[ $CHANGE_ROOT_PASSWORD == 0 && ! -v ROOT_NEW_PASSWORD ]]
fixture_root_choice=0
fixture_password='test-only:root password'
ask_root_password
[[ $CHANGE_ROOT_PASSWORD == 1 && $ROOT_NEW_PASSWORD == "$fixture_password" ]]
chpasswd() {
  [[ $# == 0 ]]
  cat > "$state_dir/password-stdin"
}
change_root_password > "$state_dir/password-output"
[[ ! -v ROOT_NEW_PASSWORD && ! -s $state_dir/password-output ]]
[[ $(< "$state_dir/password-stdin") == "root:$fixture_password" ]]

# Exercise profile paths from the archive layout without contacting upstream.
(
  WORK_DIR=$state_dir
  fixture_home="$state_dir/admin"
  mkdir "$fixture_home"
  clone_shell_component() { :; }
  curl() { printf '%s\n' '# Ajnasz Blue Theme' > "${!#}"; }
  as_admin() (
    cd -- "$fixture_home"
    "$@"
  )
  install_shell
  cmp installer/profile/mc/skins/dracula.ini "$fixture_home/.local/share/mc/skins/dracula.ini"
  cmp installer/profile/mc/skins/dracula256.ini "$fixture_home/.local/share/mc/skins/dracula256.ini"
  grep -Fxq 'skin=dracula256' "$fixture_home/.config/mc/ini"
)

printf '%s\n' 2054 1122334455667788 panel11223344 00000000000000000000000000000000 \
  > "$state_dir/install.state"
load_panel_state "$state_dir"
[[ ${#PANEL_PASSWORD} == 32 ]]
acknowledge_panel_login "$state_dir"
load_panel_state "$state_dir"
[[ -z $PANEL_PASSWORD && $PANEL_PORT == 2054 && $PANEL_PATH == 1122334455667788 ]]

printf '%s\n' 'Проверки Debian Start прошли.'
