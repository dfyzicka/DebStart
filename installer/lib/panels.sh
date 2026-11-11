# Docker, the optional 3x-ui panel and dry.

docker_local() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --host unix:///var/run/docker.sock "$@"
}

package_installed() {
  [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]
}

install_docker() {
  local package fingerprint candidate uid
  local docker_user=${ADMIN_USER:-${SUDO_USER:-${SSH_LOGIN:-}}}
  local docker_repository="https://download.docker.com/linux/$DISTRO_ID"
  if ! command -v docker >/dev/null || ! docker_local compose version >/dev/null 2>&1; then
    ensure_apt_indexes
    if package_installed docker.io; then
      case "$DISTRO_ID:$DISTRO_CODENAME" in
        ubuntu:*) apt_run install -y docker-compose-v2 ;;
        debian:trixie) apt_run install -y docker-compose ;;
        *) fail 'Для установленного docker.io нужен совместимый плагин Docker Compose.' ;;
      esac
    else
      for package in docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
        if package_installed "$package"; then
          fail "Пакет $package конфликтует с Docker CE. Сначала подготовь совместимый Docker с Compose."
        fi
      done

      candidate=$(apt-cache policy docker-ce | awk '/Candidate:/ { print $2 }')
      if [[ -z $candidate || $candidate == '(none)' ]]; then
        apt_run install -y --no-install-recommends gpg
        printf '%s\n' 'Загружаю ключ репозитория Docker.'
        curl --fail --silent --show-error --location --proto '=https' --retry 3 \
          --connect-timeout 15 --max-time 60 \
          "$docker_repository/gpg" -o "$WORK_DIR/docker.asc"
        fingerprint=$(gpg --batch --no-tty --show-keys --with-colons "$WORK_DIR/docker.asc" </dev/null |
          awk -F: '$1 == "fpr" && !seen++ { print $10 }')
        [[ $fingerprint == 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 ]] ||
          fail 'Не совпал отпечаток ключа APT-репозитория Docker.'
        install -d -m 0755 /etc/apt/keyrings
        install -m 0644 "$WORK_DIR/docker.asc" /etc/apt/keyrings/docker.asc
        cat > "$WORK_DIR/docker.sources" <<EOF
Types: deb
URIs: $docker_repository
Suites: $DISTRO_CODENAME
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        install -m 0644 "$WORK_DIR/docker.sources" /etc/apt/sources.list.d/docker.sources
        printf 'Подключаю репозиторий Docker · %s\n' "$DISTRO_CODENAME"
        apt_run update
      fi
      apt_run install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
  fi

  if ! docker_local info >/dev/null 2>&1; then
    systemctl enable --now docker.service
  fi
  docker_local info >/dev/null
  docker_local compose version

  if [[ -n $docker_user ]] && uid=$(id -u -- "$docker_user" 2>/dev/null) &&
     (( uid >= 1000 && uid != 65534 )); then
    getent group docker >/dev/null || groupadd --system docker
    usermod -aG docker -- "$docker_user"
    if ! runuser -u "$docker_user" -- env -u DOCKER_HOST -u DOCKER_CONTEXT \
      -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH docker --host unix:///var/run/docker.sock info >/dev/null; then
      fail "Не удалось подключиться к локальному Docker от имени $docker_user."
    fi
    printf 'Docker без sudo · %s · в новом сеансе\n' "$docker_user"
  fi
}

install_dry() {
  local asset="dry-linux-$ARCH" digest binary="$WORK_DIR/dry"
  curl --fail --silent --show-error --location --proto '=https' --retry 3 \
    "https://api.github.com/repos/moncho/dry/releases/tags/$DRY_VERSION" -o "$WORK_DIR/dry-release.json"
  digest=$(python3 - "$WORK_DIR/dry-release.json" "$asset" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    release = json.load(source)
for asset in release["assets"]:
    if asset["name"] == sys.argv[2]:
        digest = asset.get("digest") or ""
        if re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            print(digest.removeprefix("sha256:"))
            break
        raise SystemExit(f"GitHub не опубликовал SHA-256 для {sys.argv[2]}")
else:
    raise SystemExit(f"В релизе dry отсутствует {sys.argv[2]}")
PY
  )
  if [[ -x /usr/local/bin/dry ]] &&
     printf '%s  %s\n' "$digest" /usr/local/bin/dry | sha256sum --check --status; then
    return
  fi
  curl --fail --silent --show-error --location --proto '=https' --retry 3 \
    "https://github.com/moncho/dry/releases/download/$DRY_VERSION/$asset" -o "$binary"
  printf '%s  %s\n' "$digest" "$binary" | sha256sum --check --strict
  install -m 0755 "$binary" /usr/local/bin/dry
}

compose_panel() {
  local directory=$1
  shift
  docker_local compose --project-directory "$directory" --project-name "debian-start-${directory##*/}" \
    --env-file "$directory/compose.env" -f "$directory/compose.yml" "$@"
}

free_panel_port() {
  local port=$1 listeners last=$(( $1 + 49 ))
  for ((; port <= last; port++)); do
    listeners=$(ss -H -lnt "sport = :$port") || return
    if [[ -z $listeners ]]; then
      printf '%s\n' "$port"
      return
    fi
  done
  return 1
}

load_panel_state() {
  local directory=$1
  mapfile -t PANEL_RECORD < "$directory/install.state"
  PANEL_PORT=${PANEL_RECORD[0]-}
  PANEL_PATH=${PANEL_RECORD[1]-}
  PANEL_USER=${PANEL_RECORD[2]-}
  PANEL_PASSWORD=${PANEL_RECORD[3]-}
  if [[ ! $PANEL_PORT =~ ^[0-9]{1,5}$ ]] || (( 10#$PANEL_PORT < 1 || 10#$PANEL_PORT > 65535 )) ||
     [[ ! $PANEL_PATH =~ ^[a-f0-9]{16}$ || ! $PANEL_USER =~ ^panel[a-f0-9]{8}$ ]] ||
     [[ -n $PANEL_PASSWORD && ! $PANEL_PASSWORD =~ ^[a-f0-9]{32}$ ]]; then
    fail "Повреждён файл установки $directory/install.state."
  fi
}

prepare_panel() {
  local name=$1 start_port=$2 directory="/opt/$1" stage port path username password
  if [[ ! -e $directory ]]; then
    mkdir -p /opt
    port=$(free_panel_port "$start_port") || fail "Нет свободного порта для $name."
    path=$(openssl rand -hex 8)
    username="panel$(openssl rand -hex 4)"
    password=$(openssl rand -hex 16)
    stage=$(mktemp -d "/opt/.debian-start-$name.XXXXXXXX")
    install -m 0600 "$INSTALLER_DIR/compose/$name.yml" "$stage/compose.yml"
    printf '%s\n' "$port" "$path" "$username" "$password" > "$stage/install.state"
    : > "$stage/compose.env"
    mv -T -- "$stage" "$directory"
  fi
  [[ ! -L $directory && -f $directory/install.state && -f $directory/compose.yml &&
     -f $directory/compose.env ]] || fail "$directory уже существует. Проверь расположенную там установку $name."
  load_panel_state "$directory"
}

wait_panel() {
  local directory=$1 port=$2 path=$3 attempt listeners address
  local url="http://127.0.0.1:$port/$path/"
  printf 'Проверяю %s на 127.0.0.1:%s\n' "${directory##*/}" "$port"
  for ((attempt=0; attempt<75; attempt++)); do
    listeners=$(ss -H -lnt "sport = :$port" | awk '{ print $4 }')
    for address in $listeners; do
      if [[ $address != "127.0.0.1:$port" && $address != "[::1]:$port" ]]; then
        compose_panel "$directory" stop
        fail "Панель слушала $address. Контейнер остановлен для проверки адреса прослушивания."
      fi
    done
    if [[ $listeners == *"127.0.0.1:$port"* ]] &&
       curl --noproxy '*' --fail --silent --max-time 2 "$url" -o /dev/null; then
      printf 'HTTP отвечает на 127.0.0.1:%s\n' "$port"
      return
    fi
    sleep 1
  done
  fail "Панель $directory не ответила по адресу $url. Проверь её порт, путь и состояние контейнера."
}

initialize_xui() {
  local directory=$1 settings
  [[ -n $PANEL_PASSWORD ]] || fail 'Отсутствует пароль инициализации 3x-ui.'
  printf '%s\n' 'Настраиваю вход и адрес 3x-ui.'
  # Keep settings and verification in one container. Send credentials only over a pipe.
  settings=$(printf '%s\n' "$PANEL_USER" "$PANEL_PASSWORD" "$PANEL_PORT" "$PANEL_PATH" |
    compose_panel "$directory" run --rm -T --interactive --no-deps --entrypoint /bin/sh 3xui -ec '
      IFS= read -r login
      IFS= read -r password
      IFS= read -r port
      IFS= read -r path
      /app/x-ui setting -username "$login" -password "$password" \
        -listenIP 127.0.0.1 -port "$port" -webBasePath "/$path/" </dev/null
      /app/x-ui setting -show </dev/null
      /app/x-ui setting -getListen </dev/null
    ')
  [[ $settings == *'Username and password updated successfully'* ]] ||
    fail '3x-ui не подтвердил создание учётки панели.'
  [[ $settings == *"listenIP: 127.0.0.1"* && $settings == *"webBasePath: /$PANEL_PATH/"* ]] ||
    fail 'Не удалось проверить адрес и путь 3x-ui после инициализации.'
  touch "$directory/.initialized"
}

install_xui() {
  local directory=/opt/3x-ui image
  prepare_panel 3x-ui 2053
  install -d -m 0700 "$directory/db" "$directory/cert"
  image=$(compose_panel "$directory" config --images 3xui)
  [[ -n $image ]] || fail 'В Compose не указан образ 3x-ui.'
  if ! docker_local image inspect "$image" >/dev/null 2>&1; then
    compose_panel "$directory" pull
  fi
  if [[ ! -f $directory/.initialized ]]; then initialize_xui "$directory"; fi
  printf 'Запускаю 3x-ui · %s\n' "$image"
  compose_panel "$directory" up -d
  wait_panel "$directory" "$PANEL_PORT" "$PANEL_PATH"
  XUI_READY=1
}

acknowledge_panel_login() {
  local directory=$1 temporary
  load_panel_state "$directory"
  if [[ -n $PANEL_PASSWORD ]]; then
    temporary=$(mktemp "$directory/.state.XXXXXXXX")
    printf '%s\n' "$PANEL_PORT" "$PANEL_PATH" "$PANEL_USER" > "$temporary"
    mv -T -- "$temporary" "$directory/install.state"
  fi
}
