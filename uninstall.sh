#!/usr/bin/env bash
# uninstall.sh — Desinstalação limpa do Music Server Installer
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"
# shellcheck source=services/mountdisk.sh
source "${INSTALLER_ROOT}/services/mountdisk.sh"
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
Uso: sudo ./uninstall.sh [opções]

Opções:
  -y, --yes           Confirmar automaticamente
  --purge-data        Também remove configs/dados dos serviços
  --remove-fstab      Remove entrada de montagem do fstab
  -h, --help          Mostrar esta ajuda
EOF
}

PURGE_DATA=false
REMOVE_FSTAB=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=true; shift ;;
      --purge-data) PURGE_DATA=true; shift ;;
      --remove-fstab) REMOVE_FSTAB=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

remove_fstab_entry() {
  if declare -f remove_installer_fstab >/dev/null; then
    remove_installer_fstab
    return 0
  fi
  log_warn "Função remove_installer_fstab indisponível — fstab não alterado"
}

purge_service_data() {
  log_step "Removendo dados dos serviços (--purge-data)"
  rm -rf "${LIDARR_CONFIG_DIR}" "${PROWLARR_CONFIG_DIR}" "${PLEX_CONFIG_DIR}"
  if [[ -n "${QBITTORRENT_CONFIG_DIR:-}" ]]; then
    rm -rf "${QBITTORRENT_CONFIG_DIR}"
  fi
  log_ok "Dados dos serviços removidos"
}

main() {
  parse_args "$@"
  require_root
  print_banner

  echo -e "${C_BOLD}Desinstalação${C_RESET}"
  echo

  if ! load_state; then
    log_warn "Estado de instalação não encontrado em ${STATE_FILE}"
    log_warn "Será tentada remoção dos serviços padrão."
    INSTALL_PLEX=true
    INSTALL_LIDARR=true
    INSTALL_PROWLARR=true
    INSTALL_QBITTORRENT=true
    TARGET_USER="${SUDO_USER:-}"
    if [[ -z "${TARGET_USER}" ]]; then
      TARGET_USER="$(prompt_input "Usuário do qBittorrent (vazio = pular serviço)" "")"
    fi
    if [[ -n "${TARGET_USER}" ]] && id "${TARGET_USER}" &>/dev/null; then
      TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
      QBITTORRENT_CONFIG_DIR="${TARGET_HOME}/.config/qBittorrent"
    else
      INSTALL_QBITTORRENT=false
      log_warn "Sem usuário válido — qBittorrent não será desinstalado via template"
    fi
    PLEX_LIBRARY_NAME="Músicas"
  else
    log_ok "Estado carregado (instalado em ${INSTALLED_AT:-desconhecido})"
    echo -e "  Usuário: ${TARGET_USER}"
    echo -e "  Biblioteca: ${MUSIC_ROOT}"
  fi

  echo
  log_warn "Isso removerá os serviços instalados pelo Music Server Installer."
  log_warn "A biblioteca de músicas em disco NÃO será apagada."
  echo

  if ! confirm "Desinstalar agora?" "N"; then
    die "Desinstalação cancelada."
  fi

  # Backup antes de remover
  if [[ -d "${STATE_DIR}" ]]; then
    backup_configs >/dev/null || true
  fi

  if [[ "${INSTALL_QBITTORRENT}" == "true" ]]; then
    uninstall_qbittorrent
  fi
  if [[ "${INSTALL_PROWLARR}" == "true" ]]; then
    uninstall_prowlarr
  fi
  if [[ "${INSTALL_LIDARR}" == "true" ]]; then
    uninstall_lidarr
  fi
  if [[ "${INSTALL_PLEX}" == "true" ]]; then
    uninstall_plex
  fi

  remove_firewall_rules

  if [[ "${REMOVE_FSTAB}" == "true" ]]; then
    remove_fstab_entry
  fi

  if [[ "${PURGE_DATA}" == "true" ]]; then
    purge_service_data
  fi

  # Remover repositório Servarr se ninguém mais usa
  if [[ ! -d /opt/Lidarr && ! -d /opt/Prowlarr ]] && ! dpkg -l lidarr &>/dev/null && ! dpkg -l prowlarr &>/dev/null; then
    rm -f /etc/apt/sources.list.d/servarr.list
    rm -f /usr/share/keyrings/servarr-archive-keyring.gpg
  fi

  rm -f "${STATE_FILE}"
  log_ok "Estado de instalação removido"

  echo
  echo -e "${C_GREEN}Desinstalação concluída.${C_RESET}"
  echo -e "${C_DIM}Backups (se houver): ${BACKUP_DIR}${C_RESET}"
  echo -e "${C_DIM}Biblioteca preservada: ${MUSIC_ROOT:-n/a}${C_RESET}"
  echo
}

main "$@"
