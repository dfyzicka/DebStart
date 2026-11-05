name: debian-start-m-ui
services:
  m-ui:
    image: debian-start/m-ui:${MUI_BUILD_VERSION:?missing m-ui source revision}
    build:
      context: ./upstream
      args:
        MUI_VERSION: ${MUI_BUILD_VERSION}
    network_mode: host
    restart: unless-stopped
    environment:
      MUI_LISTEN_IP: "127.0.0.1"
      MUI_PANEL_PORT: "${MUI_PANEL_PORT:?missing panel port}"
      MUI_USERNAME: "${MUI_USERNAME:?missing panel login}"
      MUI_PATH: "${MUI_PATH:?missing panel path}"
      TZ: "${MUI_TZ:-Etc/UTC}"
    volumes:
      - ./data:/opt/m-ui/data
      - ./core:/opt/m-ui/core
    logging:
      driver: local
