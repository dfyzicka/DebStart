# Docker, the optional panels and dry.

docker_local() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --host unix:///var/run/docker.sock "$@"
}

package_installed() {
  [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]
}

install_docker() {
  local package fingerprint candidate
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
        curl --fail --silent --show-error --location --proto '=https' --retry 3 \
          "$docker_repository/gpg" -o "$WORK_DIR/docker.asc"
        fingerprint=$(gpg --batch --show-keys --with-colons "$WORK_DIR/docker.asc" |
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

install_xui() {
  local directory=/opt/3x-ui initialized settings listen
  prepare_panel 3x-ui 2053
  install -d -m 0700 "$directory/db" "$directory/cert"
  compose_panel "$directory" config --quiet
  if ! docker_local image inspect ghcr.io/mhsanaei/3x-ui:v3.11.0 >/dev/null 2>&1; then
    compose_panel "$directory" pull
  fi
  if [[ ! -f $directory/.initialized ]]; then
    [[ -n $PANEL_PASSWORD ]] || fail 'Отсутствует пароль инициализации 3x-ui.'
    # Pass credentials on stdin so they stay out of the Docker container config.
    initialized=$(printf '%s\n' "$PANEL_USER" "$PANEL_PASSWORD" "$PANEL_PORT" "$PANEL_PATH" |
      compose_panel "$directory" run --rm -T --no-deps --entrypoint /bin/sh 3xui -ec '
        IFS= read -r login
        IFS= read -r password
        IFS= read -r port
        IFS= read -r path
        exec /app/x-ui setting -username "$login" -password "$password" \
          -listenIP 127.0.0.1 -port "$port" -webBasePath "/$path/"
      ')
    [[ $initialized == *'Username and password updated successfully'* ]] ||
      fail '3x-ui не подтвердил создание учётки панели.'
    settings=$(compose_panel "$directory" run --rm -T --no-deps --entrypoint /app/x-ui 3xui setting -show)
    listen=$(compose_panel "$directory" run --rm -T --no-deps --entrypoint /app/x-ui 3xui setting -getListen)
    [[ $listen == *"listenIP: 127.0.0.1"* && $settings == *"webBasePath: /$PANEL_PATH/"* ]] ||
      fail 'Не удалось проверить адрес и путь 3x-ui после инициализации.'
    touch "$directory/.initialized"
  fi
  compose_panel "$directory" up -d
  wait_panel "$directory" "$PANEL_PORT" "$PANEL_PATH"
  READY_PANELS+=(3x-ui)
}

install_mui() {
  local directory=/opt/m-ui source revision timezone
  prepare_panel m-ui 2054
  if [[ ! -d $directory/upstream/.git ]]; then
    source=$(mktemp -d "$directory/.upstream.XXXXXXXX")
    git clone --depth 1 --single-branch --branch main https://github.com/RomanovCaesar/m-ui.git "$source"
    mv -T -- "$source" "$directory/upstream"
  fi
  revision=$(git -C "$directory/upstream" rev-parse --short=12 HEAD)
  [[ $revision =~ ^[0-9a-f]{12}$ ]] || fail 'Не удалось определить ревизию m-ui.'
  grep -q 'MUI_LISTEN_IP' "$directory/upstream/docker-compose.yml" ||
    fail 'В исходном Compose m-ui отсутствует настройка адреса панели.'
  timezone=$(timedatectl show --property=Timezone --value)
  [[ $timezone =~ ^[A-Za-z0-9/_+-]+$ ]] || timezone=Etc/UTC
  printf 'MUI_BUILD_VERSION=%s\nMUI_PANEL_PORT=%s\nMUI_USERNAME=%s\nMUI_PATH=%s\nMUI_TZ=%s\n' \
    "$revision" "$PANEL_PORT" "$PANEL_USER" "$PANEL_PATH" "$timezone" > "$directory/compose.env"
  install -d -m 0700 "$directory/data" "$directory/core"
  compose_panel "$directory" config --quiet
  if ! docker_local image inspect "debian-start/m-ui:$revision" >/dev/null 2>&1; then
    compose_panel "$directory" build
  fi

  if [[ ! -s $directory/data/state.json ]]; then
    [[ -n $PANEL_PASSWORD ]] || fail 'Отсутствует файл состояния m-ui.'
    MUI_FIRST_PASSWORD=$PANEL_PASSWORD compose_panel "$directory" \
      -f "$INSTALLER_DIR/compose/m-ui-first-run.yml" up -d --no-build
    wait_panel "$directory" "$PANEL_PORT" "$PANEL_PATH"
    [[ -s $directory/data/state.json ]] || fail 'm-ui не сохранил состояние первого запуска.'
  fi
  # Recreate the first-run container with the regular config, clearing init credentials.
  compose_panel "$directory" up -d --no-build
  wait_panel "$directory" "$PANEL_PORT" "$PANEL_PATH"
  READY_PANELS+=(m-ui)
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
