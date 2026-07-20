#!/usr/bin/env bash
# install.sh — Orquestrador interativo do Music Server Installer
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"
# shellcheck source=services/mountdisk.sh
source "${INSTALLER_ROOT}/services/mountdisk.sh"
# shellcheck source=services/permissions.sh
source "${INSTALLER_ROOT}/services/permissions.sh"
# shellcheck source=services/firewall.sh
source "${INSTALLER_ROOT}/services/firewall.sh"
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
Uso: sudo ./install.sh [opções]

Opções:
  -y, --yes              Confirmar automaticamente
  --skip-system-update   Não executar apt upgrade
  -h, --help             Mostrar esta ajuda
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=true; shift ;;
      --skip-system-update) SKIP_SYSTEM_UPDATE=true; shift ;;
      --dry-run)
        die "Dry-run completo ainda não implementado. Remova --dry-run para instalar de verdade."
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

show_summary() {
  print_separator
  echo -e "${C_BOLD}Resumo da instalação${C_RESET}"
  echo
  echo -e "  Usuário:     ${TARGET_USER}"
  echo -e "  Disco:       ${DISK_LABEL} (${DISK_DEVICE})"
  echo -e "  Montagem:    ${MOUNT_POINT}"
  echo -e "  Biblioteca:  ${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
  echo -e "  Plex lib:    ${PLEX_LIBRARY_NAME}"
  echo
  echo -e "  Serviços:"
  [[ "${INSTALL_PLEX}" == "true" ]]        && echo -e "    ${C_GREEN}✓${C_RESET} Plex"
  [[ "${INSTALL_LIDARR}" == "true" ]]      && echo -e "    ${C_GREEN}✓${C_RESET} Lidarr"
  [[ "${INSTALL_PROWLARR}" == "true" ]]    && echo -e "    ${C_GREEN}✓${C_RESET} Prowlarr"
  [[ "${INSTALL_QBITTORRENT}" == "true" ]] && echo -e "    ${C_GREEN}✓${C_RESET} qBittorrent"
  echo
}

main() {
  parse_args "$@"
  require_root
  print_banner
  detect_os

  # --- Fase interativa ---
  print_separator
  select_disk

  print_separator
  echo
  select_user

  print_separator
  echo
  echo -e "${C_BOLD}Nome da biblioteca Plex${C_RESET}"
  echo
  PLEX_LIBRARY_NAME="$(prompt_input "Nome" "Músicas")"
  [[ -z "${PLEX_LIBRARY_NAME}" ]] && PLEX_LIBRARY_NAME="Músicas"
  echo

  print_separator
  echo
  select_services

  # Definir MUSIC_ROOT se ainda não definido
  MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
  DOWNLOADS_DIR="${MUSIC_ROOT}/Downloads"
  INCOMPLETE_DIR="${MUSIC_ROOT}/Downloads/Incomplete"

  show_summary

  if ! confirm "Continuar?"; then
    die "Instalação cancelada pelo usuário."
  fi

  echo
  echo -e "${C_BOLD}Iniciando instalação...${C_RESET}"
  echo

  # --- Fase automática ---
  ensure_media_group_early
  update_system
  install_dependencies
  configure_ntfs_mount
  create_music_folders

  if [[ "${INSTALL_PLEX}" == "true" ]]; then
    install_plex
  fi
  if [[ "${INSTALL_QBITTORRENT}" == "true" ]]; then
    install_qbittorrent
  fi
  if [[ "${INSTALL_LIDARR}" == "true" ]]; then
    install_lidarr
  fi
  if [[ "${INSTALL_PROWLARR}" == "true" ]]; then
    install_prowlarr
  fi

  configure_permissions
  reapply_media_group
  configure_firewall

  save_state

  echo
  log_ok "Finalizado"
  print_final_urls
}

main "$@"
