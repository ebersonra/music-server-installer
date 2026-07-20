#!/usr/bin/env bash
# update.sh — Atualização dos serviços do Music Server Installer
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"
# shellcheck source=services/plex.sh
source "${INSTALLER_ROOT}/services/plex.sh"
# shellcheck source=services/lidarr.sh
source "${INSTALLER_ROOT}/services/lidarr.sh"
# shellcheck source=services/prowlarr.sh
source "${INSTALLER_ROOT}/services/prowlarr.sh"
# shellcheck source=services/qbittorrent.sh
source "${INSTALLER_ROOT}/services/qbittorrent.sh"

usage() {
  cat <<EOF
Uso: sudo ./update.sh [opções]

Atualiza os serviços previamente instalados pelo install.sh.

Opções:
  -y, --yes              Confirmar automaticamente
  --skip-system-update   Não executar apt update/upgrade geral
  --backup               Fazer backup das configs antes
  -h, --help             Mostrar esta ajuda
EOF
}

DO_BACKUP=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=true; shift ;;
      --skip-system-update) SKIP_SYSTEM_UPDATE=true; shift ;;
      --backup) DO_BACKUP=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_root
  print_banner

  echo -e "${C_BOLD}Atualização de serviços${C_RESET}"
  echo

  if ! load_state; then
    die "Nenhuma instalação encontrada (${STATE_FILE}). Execute ./install.sh primeiro."
  fi

  detect_os

  echo -e "  Instalado em:  ${INSTALLED_AT:-desconhecido}"
  echo -e "  Usuário:       ${TARGET_USER}"
  echo -e "  Biblioteca:    ${MUSIC_ROOT}"
  echo
  echo -e "  Serviços a atualizar:"
  [[ "${INSTALL_PLEX}" == "true" ]]        && echo -e "    ${C_GREEN}✓${C_RESET} Plex"
  [[ "${INSTALL_LIDARR}" == "true" ]]      && echo -e "    ${C_GREEN}✓${C_RESET} Lidarr"
  [[ "${INSTALL_PROWLARR}" == "true" ]]    && echo -e "    ${C_GREEN}✓${C_RESET} Prowlarr"
  [[ "${INSTALL_QBITTORRENT}" == "true" ]] && echo -e "    ${C_GREEN}✓${C_RESET} qBittorrent"
  echo

  if ! confirm "Continuar com a atualização?"; then
    die "Atualização cancelada."
  fi

  if [[ "${DO_BACKUP}" == "true" ]]; then
    log_step "Backup das configurações"
    local dest
    dest="$(backup_configs)"
    log_ok "Backup em ${dest}"
  fi

  if [[ "${SKIP_SYSTEM_UPDATE}" != "true" ]]; then
    log_step "Atualizando índices APT"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
  fi

  if [[ "${INSTALL_PLEX}" == "true" ]]; then
    update_plex
  fi
  if [[ "${INSTALL_QBITTORRENT}" == "true" ]]; then
    update_qbittorrent
  fi
  if [[ "${INSTALL_LIDARR}" == "true" ]]; then
    update_lidarr
  fi
  if [[ "${INSTALL_PROWLARR}" == "true" ]]; then
    update_prowlarr
  fi

  # Atualizar versão no estado (valores com quoting seguro)
  if [[ -f "${STATE_FILE}" ]]; then
    local tmp_state new_version
    # Versão atual do instalador (de config.sh), não a do state antigo
    new_version="$(
      # shellcheck source=config.sh
      source "${INSTALLER_ROOT}/config.sh"
      printf '%s' "${INSTALLER_VERSION}"
    )"
    tmp_state="$(mktemp)"
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    {
      printf 'INSTALLER_VERSION=%q\n' "${new_version}"
      printf 'INSTALLED_AT=%q\n' "${INSTALLED_AT:-}"
      printf 'UPDATED_AT=%q\n' "$(date -Iseconds)"
      printf 'TARGET_USER=%q\n' "${TARGET_USER}"
      printf 'TARGET_UID=%q\n' "${TARGET_UID}"
      printf 'TARGET_GID=%q\n' "${TARGET_GID}"
      printf 'TARGET_HOME=%q\n' "${TARGET_HOME}"
      printf 'DISK_DEVICE=%q\n' "${DISK_DEVICE}"
      printf 'DISK_LABEL=%q\n' "${DISK_LABEL}"
      printf 'DISK_FSTYPE=%q\n' "${DISK_FSTYPE}"
      printf 'MOUNT_POINT=%q\n' "${MOUNT_POINT}"
      printf 'MUSIC_ROOT=%q\n' "${MUSIC_ROOT}"
      printf 'DOWNLOADS_DIR=%q\n' "${DOWNLOADS_DIR}"
      printf 'INCOMPLETE_DIR=%q\n' "${INCOMPLETE_DIR}"
      printf 'PLEX_LIBRARY_NAME=%q\n' "${PLEX_LIBRARY_NAME}"
      printf 'INSTALL_PLEX=%q\n' "${INSTALL_PLEX}"
      printf 'INSTALL_LIDARR=%q\n' "${INSTALL_LIDARR}"
      printf 'INSTALL_PROWLARR=%q\n' "${INSTALL_PROWLARR}"
      printf 'INSTALL_QBITTORRENT=%q\n' "${INSTALL_QBITTORRENT}"
    } > "${tmp_state}"
    mv "${tmp_state}" "${STATE_FILE}"
    chmod 600 "${STATE_FILE}"
  fi

  echo
  log_ok "Atualização concluída"
  local ip
  ip="$(get_local_ip)"
  echo
  [[ "${INSTALL_PLEX}" == "true" ]]        && echo -e "${C_DIM}Plex         http://${ip}:${PORT_PLEX}/web${C_RESET}"
  [[ "${INSTALL_LIDARR}" == "true" ]]      && echo -e "${C_DIM}Lidarr       http://${ip}:${PORT_LIDARR}${C_RESET}"
  [[ "${INSTALL_PROWLARR}" == "true" ]]    && echo -e "${C_DIM}Prowlarr     http://${ip}:${PORT_PROWLARR}${C_RESET}"
  [[ "${INSTALL_QBITTORRENT}" == "true" ]] && echo -e "${C_DIM}qBittorrent  http://${ip}:${PORT_QBITTORRENT}${C_RESET}"
  echo
}

main "$@"
