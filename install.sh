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

INSTALL_ERRORS=()

# Executa um passo; em falha registra e continua (não aborta o instalador)
# Roda em subshell para que die()/exit internos não matem o install.sh
run_install_step() {
  local name="$1"
  shift
  set +e
  (
    set -euo pipefail
    "$@"
  )
  local rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    log_error "${name} falhou (código ${rc}) — continuando a instalação"
    INSTALL_ERRORS+=("${name}")
  fi
  return 0
}

show_summary() {
  print_separator
  echo -e "${C_BOLD}Resumo da instalação${C_RESET}"
  echo
  echo -e "  Usuário:     ${TARGET_USER}"
  echo -e "  Disco:       ${DISK_LABEL} (${DISK_DEVICE})"
  echo -e "  Montagem:    ${MOUNT_POINT}"
  echo -e "  Músicas:     ${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
  echo -e "  Fotos:       ${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}"
  echo -e "  Plex music:  ${PLEX_LIBRARY_NAME}"
  echo -e "  Plex photos: ${PLEX_PHOTOS_LIBRARY_NAME}"
  echo
  echo -e "  Serviços:"
  [[ "${INSTALL_PLEX}" == "true" ]]        && echo -e "    ${C_GREEN}✓${C_RESET} Plex"
  [[ "${INSTALL_LIDARR}" == "true" ]]      && echo -e "    ${C_GREEN}✓${C_RESET} Lidarr"
  [[ "${INSTALL_PROWLARR}" == "true" ]]    && echo -e "    ${C_GREEN}✓${C_RESET} Prowlarr"
  [[ "${INSTALL_QBITTORRENT}" == "true" ]] && echo -e "    ${C_GREEN}✓${C_RESET} qBittorrent"
  echo
}

show_install_errors() {
  if [[ ${#INSTALL_ERRORS[@]} -eq 0 ]]; then
    return 0
  fi
  echo
  print_separator
  log_warn "Alguns passos falharam:"
  local e
  for e in "${INSTALL_ERRORS[@]}"; do
    echo -e "  ${C_RED}✗${C_RESET}  ${e}"
  done
  echo
  echo -e "${C_DIM}Reexecute: sudo ./install.sh  (ou corrija o serviço e rode sudo ./update.sh)${C_RESET}"
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
  echo -e "${C_BOLD}Nome da biblioteca Plex (músicas)${C_RESET}"
  echo
  PLEX_LIBRARY_NAME="$(prompt_input "Nome" "Músicas")"
  [[ -z "${PLEX_LIBRARY_NAME}" ]] && PLEX_LIBRARY_NAME="Músicas"
  echo

  print_separator
  echo
  echo -e "${C_BOLD}Nome da biblioteca Plex (fotos)${C_RESET}"
  echo
  PLEX_PHOTOS_LIBRARY_NAME="$(prompt_input "Nome" "Fotos")"
  [[ -z "${PLEX_PHOTOS_LIBRARY_NAME}" ]] && PLEX_PHOTOS_LIBRARY_NAME="Fotos"
  echo

  print_separator
  echo
  select_services

  # Definir roots se ainda não definidos
  MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
  DOWNLOADS_DIR="${MUSIC_ROOT}/Downloads"
  INCOMPLETE_DIR="${MUSIC_ROOT}/Downloads/Incomplete"
  PHOTOS_ROOT="${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}"

  show_summary

  if ! confirm "Continuar?"; then
    die "Instalação cancelada pelo usuário."
  fi

  echo
  echo -e "${C_BOLD}Iniciando instalação...${C_RESET}"
  echo

  # --- Fase automática (passos críticos) ---
  ensure_media_group_early
  update_system
  install_dependencies
  configure_ntfs_mount
  create_music_folders

  # --- Serviços: falha de um não aborta os demais ---
  if [[ "${INSTALL_PLEX}" == "true" ]]; then
    run_install_step "Plex" install_plex
  fi
  if [[ "${INSTALL_QBITTORRENT}" == "true" ]]; then
    run_install_step "qBittorrent" install_qbittorrent
  fi
  if [[ "${INSTALL_LIDARR}" == "true" ]]; then
    run_install_step "Lidarr" install_lidarr
  fi
  if [[ "${INSTALL_PROWLARR}" == "true" ]]; then
    run_install_step "Prowlarr" install_prowlarr
  fi

  run_install_step "Permissões" configure_permissions
  run_install_step "Grupo media" reapply_media_group
  run_install_step "Firewall" configure_firewall

  save_state

  echo
  if [[ ${#INSTALL_ERRORS[@]} -eq 0 ]]; then
    log_ok "Finalizado"
  else
    log_warn "Finalizado com avisos"
  fi
  print_final_urls
  show_install_errors

  # Exit 1 só se algum serviço falhou (útil para automação)
  [[ ${#INSTALL_ERRORS[@]} -eq 0 ]]
}

main "$@"
