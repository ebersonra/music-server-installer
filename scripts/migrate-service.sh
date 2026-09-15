#!/usr/bin/env bash
# Migração assistida — um serviço por vez.
# Uso: sudo ./scripts/migrate-service.sh flaresolverr|qbittorrent|prowlarr|lidarr|plex
set -euo pipefail
ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
SERVICE="${1:?informe o serviço}"

# shellcheck source=../common.sh
source "${ROOT}/common.sh"
# shellcheck source=../services/docker.sh
source "${ROOT}/services/docker.sh"
# shellcheck source=../services/flaresolverr.sh
source "${ROOT}/services/flaresolverr.sh"
# shellcheck source=../services/qbittorrent.sh
source "${ROOT}/services/qbittorrent.sh"
# shellcheck source=../services/prowlarr.sh
source "${ROOT}/services/prowlarr.sh"
# shellcheck source=../services/lidarr.sh
source "${ROOT}/services/lidarr.sh"
# shellcheck source=../services/plex.sh
source "${ROOT}/services/plex.sh"

require_root
ASSUME_YES=true

if ! load_state; then
  TARGET_USER="${SUDO_USER:-eberson}"
  TARGET_UID="$(id -u "${TARGET_USER}")"
  TARGET_GID="$(id -g "${TARGET_USER}")"
  TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
  MOUNT_POINT="/media/music"
  MUSIC_ROOT="${MOUNT_POINT}/Musicas"
  DOWNLOADS_DIR="${MUSIC_ROOT}/Downloads"
  INCOMPLETE_DIR="${DOWNLOADS_DIR}/Incomplete"
  PHOTOS_ROOT="${MOUNT_POINT}/Fotos"
  INSTALL_PLEX=true INSTALL_LIDARR=true INSTALL_PROWLARR=true
  INSTALL_QBITTORRENT=true INSTALL_FLARESOLVERR=true
  PLEX_LIBRARY_NAME="Músicas"
  PLEX_PHOTOS_LIBRARY_NAME="Fotos"
fi

MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-${MUSIC_ROOT}/Downloads}"
INCOMPLETE_DIR="${INCOMPLETE_DIR:-${DOWNLOADS_DIR}/Incomplete}"
PHOTOS_ROOT="${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}"
DEPLOY_MODE=docker

ensure_docker
[[ -f "${ROOT}/.env" ]] || write_compose_env

case "${SERVICE}" in
  flaresolverr) install_flaresolverr ;;
  qbittorrent)  install_qbittorrent ;;
  prowlarr)     install_prowlarr ;;
  lidarr)       install_lidarr ;;
  plex)         install_plex ;;
  *) die "Serviço desconhecido: ${SERVICE}" ;;
esac

compose ps
log_ok "Migração de ${SERVICE} concluída"
