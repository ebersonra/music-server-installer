#!/usr/bin/env bash
# services/docker.sh — Helpers Docker Compose (ADR-0001)
# shellcheck disable=SC2154

COMPOSE_FILE="${INSTALLER_ROOT}/docker-compose.yml"
COMPOSE_ENV_FILE="${INSTALLER_ROOT}/.env"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/var/lib/music-server}"

# Hostnames internos da rede Compose (wiring setup-media-stack)
DOCKER_HOST_QBITTORRENT="qbittorrent"
DOCKER_HOST_PROWLARR="prowlarr"
DOCKER_HOST_LIDARR="lidarr"
DOCKER_HOST_FLARESOLVERR="flaresolverr"

ensure_docker() {
  if ! command -v docker &>/dev/null; then
    log_info "Instalando Docker (docker.io)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq docker.io docker-compose-v2 || {
      apt-get install -y -qq docker.io || die "Falha ao instalar docker.io"
      log_warn "Pacote docker-compose-v2 indisponível — tentando plugin do usuário/gh"
    }
  fi

  if ! docker info &>/dev/null; then
    systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true
  fi

  if ! docker info &>/dev/null; then
    die "Docker não está acessível. Instale/inicie o serviço docker e tente de novo."
  fi

  if ! docker compose version &>/dev/null; then
    log_info "Instalando Docker Compose v2..."
    export DEBIAN_FRONTEND=noninteractive
    if apt-get install -y -qq docker-compose-v2 2>/dev/null; then
      :
    else
      local plugin_dir="/usr/local/lib/docker/cli-plugins"
      mkdir -p "${plugin_dir}"
      local arch
      arch="$(uname -m)"
      case "${arch}" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) die "Arch não suportada para Compose binário: ${arch}" ;;
      esac
      curl -fsSL "https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-${arch}" \
        -o "${plugin_dir}/docker-compose"
      chmod +x "${plugin_dir}/docker-compose"
      mkdir -p /usr/libexec/docker/cli-plugins
      ln -sfn "${plugin_dir}/docker-compose" /usr/libexec/docker/cli-plugins/docker-compose
    fi
  fi

  if ! docker compose version &>/dev/null; then
    die "Docker Compose v2 não encontrado (docker compose). Instale docker-compose-v2."
  fi

  log_ok "Docker $(docker --version | head -1) · Compose $(docker compose version --short 2>/dev/null || echo ok)"
}

compose() {
  docker compose --project-directory "${INSTALLER_ROOT}" -f "${COMPOSE_FILE}" --env-file "${COMPOSE_ENV_FILE}" "$@"
}

# GID do grupo media (fallback: TARGET_GID)
_media_gid() {
  local gid
  gid="$(getent group media 2>/dev/null | cut -d: -f3 || true)"
  if [[ -n "${gid}" ]]; then
    printf '%s' "${gid}"
  else
    printf '%s' "${TARGET_GID:-1000}"
  fi
}

write_compose_env() {
  local puid="${TARGET_UID:-1000}"
  local pgid
  pgid="$(_media_gid)"
  local qbit_config_parent="${DOCKER_DATA_ROOT}/qbittorrent"
  local lidarr_cfg="${DOCKER_DATA_ROOT}/lidarr"
  local prowlarr_cfg="${DOCKER_DATA_ROOT}/prowlarr"
  local plex_cfg="${DOCKER_DATA_ROOT}/plex"

  # Migração: reutilizar configs nativas se existirem e o destino Docker ainda não
  if [[ -f /var/lib/lidarr/config.xml && ! -f "${lidarr_cfg}/config.xml" ]]; then
    lidarr_cfg="/var/lib/lidarr"
  fi
  if [[ -f /var/lib/prowlarr/config.xml && ! -f "${prowlarr_cfg}/config.xml" ]]; then
    prowlarr_cfg="/var/lib/prowlarr"
  fi
  if [[ -d /var/lib/plexmediaserver/Library && ! -d "${plex_cfg}/Library" ]]; then
    plex_cfg="/var/lib/plexmediaserver"
  fi
  if [[ -n "${TARGET_HOME:-}" && -f "${TARGET_HOME}/.config/qBittorrent/qBittorrent.conf" ]]; then
    # LinuxServer espera /config/qBittorrent/...
    qbit_config_parent="${TARGET_HOME}/.config"
  fi

  mkdir -p "${DOCKER_DATA_ROOT}" \
    "${lidarr_cfg}" "${prowlarr_cfg}" "${qbit_config_parent}/qBittorrent" "${plex_cfg}" \
    "${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}/Artistas" \
    "${DOWNLOADS_DIR:-${MUSIC_ROOT}/Downloads}/Incomplete" \
    "${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}"

  # Exportar paths efetivos para o restante do installer
  LIDARR_CONFIG_DIR="${lidarr_cfg}"
  PROWLARR_CONFIG_DIR="${prowlarr_cfg}"
  QBITTORRENT_CONFIG_DIR="${qbit_config_parent}"
  PLEX_CONFIG_DIR="${plex_cfg}"

  cat > "${COMPOSE_ENV_FILE}" <<EOF
# Gerado pelo Music Server Installer — não editar à mão se for regenerar
# Versionamento: docs/docker-versioning.md (sempre release estável)

TZ=${TZ:-America/Sao_Paulo}
PUID=${puid}
PGID=${pgid}

MOUNT_POINT=${MOUNT_POINT}
MUSIC_ROOT=${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}
DOWNLOADS_DIR=${DOWNLOADS_DIR:-${MUSIC_ROOT}/Downloads}
PHOTOS_ROOT=${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}

LIDARR_CONFIG_DIR=${lidarr_cfg}
PROWLARR_CONFIG_DIR=${prowlarr_cfg}
QBITTORRENT_CONFIG_DIR=${qbit_config_parent}
PLEX_CONFIG_DIR=${plex_cfg}

PORT_PLEX=${PORT_PLEX:-32400}
PORT_LIDARR=${PORT_LIDARR:-8686}
PORT_PROWLARR=${PORT_PROWLARR:-9696}
PORT_QBITTORRENT=${PORT_QBITTORRENT:-8080}
PORT_FLARESOLVERR=${PORT_FLARESOLVERR:-8191}
QBIT_TORRENTING_PORT=6881

FLARESOLVERR_IMAGE=ghcr.io/flaresolverr/flaresolverr
FLARESOLVERR_TAG=latest

QBITTORRENT_IMAGE=lscr.io/linuxserver/qbittorrent
QBITTORRENT_TAG=latest

PROWLARR_IMAGE=lscr.io/linuxserver/prowlarr
PROWLARR_TAG=latest

LIDARR_IMAGE=lscr.io/linuxserver/lidarr
LIDARR_TAG=latest

PLEX_IMAGE=lscr.io/linuxserver/plex
PLEX_TAG=latest

PLEX_CLAIM=

# Anúncio na LAN / app mobile (preenchido automaticamente se vazio)
PLEX_ADVERTISE_IP=
PLEX_ALLOWED_NETWORKS=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12

FLARESOLVERR_LOG_LEVEL=info
FLARESOLVERR_LOG_HTML=false
FLARESOLVERR_CAPTCHA_SOLVER=none
EOF

  # Preencher ADVERTISE_IP com IP da LAN se ainda vazio
  local lan_ip=""
  if command -v get_local_ip &>/dev/null; then
    lan_ip="$(get_local_ip 2>/dev/null || true)"
  fi
  if [[ -z "${lan_ip}" || "${lan_ip}" == "127.0.0.1" ]]; then
    lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -n "${lan_ip}" && "${lan_ip}" != "127.0.0.1" ]]; then
    if grep -q '^PLEX_ADVERTISE_IP=$' "${COMPOSE_ENV_FILE}" 2>/dev/null \
      || grep -q '^PLEX_ADVERTISE_IP=$' "${COMPOSE_ENV_FILE}" 2>/dev/null; then
      sed -i "s|^PLEX_ADVERTISE_IP=.*|PLEX_ADVERTISE_IP=http://${lan_ip}:${PORT_PLEX:-32400}/|" "${COMPOSE_ENV_FILE}"
    elif ! grep -q '^PLEX_ADVERTISE_IP=' "${COMPOSE_ENV_FILE}"; then
      echo "PLEX_ADVERTISE_IP=http://${lan_ip}:${PORT_PLEX:-32400}/" >> "${COMPOSE_ENV_FILE}"
    fi
  fi

  chmod 600 "${COMPOSE_ENV_FILE}"
  chown "${puid}:${pgid}" "${lidarr_cfg}" "${prowlarr_cfg}" "${qbit_config_parent}" "${plex_cfg}" 2>/dev/null || true
  log_ok "Arquivo Compose .env escrito em ${COMPOSE_ENV_FILE}"
}

_stop_native_unit() {
  local unit="$1"
  if systemctl list-unit-files "${unit}" &>/dev/null || systemctl status "${unit}" &>/dev/null; then
    systemctl stop "${unit}" 2>/dev/null || true
    systemctl disable "${unit}" 2>/dev/null || true
    log_info "Unit nativa parada/desabilitada: ${unit}"
  fi
}

compose_up_service() {
  local service="$1"
  ensure_docker
  if [[ ! -f "${COMPOSE_ENV_FILE}" ]]; then
    write_compose_env
  fi
  log_info "Subindo container: ${service}"
  compose pull "${service}" || log_warn "pull de ${service} falhou — tentando imagem local"
  compose up -d --remove-orphans "${service}"
}

compose_down_service() {
  local service="$1"
  if [[ -f "${COMPOSE_ENV_FILE}" ]]; then
    compose stop "${service}" 2>/dev/null || true
    compose rm -f "${service}" 2>/dev/null || true
  fi
}

compose_update_services() {
  ensure_docker
  [[ -f "${COMPOSE_ENV_FILE}" ]] || write_compose_env
  local services=("$@")
  if [[ ${#services[@]} -eq 0 ]]; then
    compose pull
    compose up -d --remove-orphans
  else
    compose pull "${services[@]}"
    compose up -d --remove-orphans "${services[@]}"
  fi
}

wait_compose_healthy() {
  local service="$1"
  local port="$2"
  local timeout="${3:-90}"
  if wait_for_port "${port}" "${timeout}"; then
    log_ok "${service} respondendo na porta ${port}"
    return 0
  fi
  log_warn "${service}: porta ${port} não abriu a tempo"
  compose logs --tail 40 "${service}" || true
  return 1
}

validate_http() {
  local name="$1"
  local url="$2"
  local retries="${3:-10}"
  local i=0
  local code="000"
  while (( i < retries )); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "${url}" 2>/dev/null || true)"
    [[ -z "${code}" ]] && code="000"
    if [[ "${code}" =~ ^(200|301|302|401|404)$ ]]; then
      log_ok "${name} HTTP ${code} (${url})"
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  log_error "${name} HTTP ${code} (${url})"
  return 1
}
