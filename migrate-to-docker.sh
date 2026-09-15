#!/usr/bin/env bash
# migrate-to-docker.sh — Migra stack systemd → Docker, um serviço por vez
# Ordem: FlareSolverr → qBittorrent → Prowlarr → Lidarr → Plex
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"
# shellcheck source=services/docker.sh
source "${INSTALLER_ROOT}/services/docker.sh"
# shellcheck source=services/flaresolverr.sh
source "${INSTALLER_ROOT}/services/flaresolverr.sh"
# shellcheck source=services/qbittorrent.sh
source "${INSTALLER_ROOT}/services/qbittorrent.sh"
# shellcheck source=services/prowlarr.sh
source "${INSTALLER_ROOT}/services/prowlarr.sh"
# shellcheck source=services/lidarr.sh
source "${INSTALLER_ROOT}/services/lidarr.sh"
# shellcheck source=services/plex.sh
source "${INSTALLER_ROOT}/services/plex.sh"

usage() {
  cat <<EOF
Uso: sudo ./migrate-to-docker.sh [opções]

Migra serviços nativos (systemd) para Docker Compose, validando cada um.

Opções:
  -y, --yes     Não pedir confirmação entre serviços
  --from N      Começar a partir do passo N (1=FlareSolverr … 5=Plex)
  -h, --help    Esta ajuda
EOF
}

START_FROM=1

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=true; shift ;;
      --from)
        START_FROM="${2:?}"
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

_validate_stack_partial() {
  local step="$1"
  local ok=0
  (( step >= 1 )) && validate_http "FlareSolverr" "http://127.0.0.1:${PORT_FLARESOLVERR}/" || ok=1
  (( step >= 2 )) && validate_http "qBittorrent" "http://127.0.0.1:${PORT_QBITTORRENT}/" || ok=1
  (( step >= 3 )) && validate_http "Prowlarr" "http://127.0.0.1:${PORT_PROWLARR}/ping" || ok=1
  (( step >= 4 )) && validate_http "Lidarr" "http://127.0.0.1:${PORT_LIDARR}/ping" || ok=1
  (( step >= 5 )) && validate_http "Plex" "http://127.0.0.1:${PORT_PLEX}/identity" || ok=1
  return "${ok}"
}

_run_step() {
  local n="$1" name="$2"
  shift 2
  if (( n < START_FROM )); then
    log_info "Pulando passo ${n} (${name})"
    return 0
  fi
  print_separator
  echo -e "${C_BOLD}Passo ${n}/5 — ${name}${C_RESET}"
  if ! confirm "Migrar ${name} para Docker agora?"; then
    die "Migração interrompida no passo ${n} (${name}). Retome com: sudo ./migrate-to-docker.sh --from ${n}"
  fi
  "$@"
  _validate_stack_partial "${n}" || die "Validação falhou após ${name}"
  log_ok "Passo ${n} OK — ${name} em Docker"
  compose ps
}

main() {
  parse_args "$@"
  require_root
  print_banner

  if ! load_state; then
    die "Nenhuma instalação encontrada (${STATE_FILE}). Execute ./install.sh primeiro."
  fi

  MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
  DOWNLOADS_DIR="${DOWNLOADS_DIR:-${MUSIC_ROOT}/Downloads}"
  INCOMPLETE_DIR="${INCOMPLETE_DIR:-${DOWNLOADS_DIR}/Incomplete}"
  PHOTOS_ROOT="${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}"
  QBITTORRENT_CONFIG_DIR="${TARGET_HOME}/.config/qBittorrent"

  echo -e "${C_BOLD}Migração systemd → Docker${C_RESET}"
  echo
  echo -e "  Usuário:  ${TARGET_USER}"
  echo -e "  Montagem: ${MOUNT_POINT}"
  echo -e "  Ordem:    FlareSolverr → qBittorrent → Prowlarr → Lidarr → Plex"
  echo
  log_warn "Cada unit systemd será parada antes de subir o container na mesma porta."
  echo

  if ! confirm "Iniciar migração?"; then
    die "Cancelado."
  fi

  ensure_docker
  write_compose_env

  # Salvar flag de deploy no state
  if [[ -f "${STATE_FILE}" ]]; then
    grep -q '^DEPLOY_MODE=' "${STATE_FILE}" 2>/dev/null \
      && sed -i "s|^DEPLOY_MODE=.*|DEPLOY_MODE=docker|" "${STATE_FILE}" \
      || echo "DEPLOY_MODE=docker" >> "${STATE_FILE}"
  fi

  _run_step 1 "FlareSolverr" install_flaresolverr
  _run_step 2 "qBittorrent" install_qbittorrent
  _run_step 3 "Prowlarr" install_prowlarr
  _run_step 4 "Lidarr" install_lidarr
  _run_step 5 "Plex" install_plex

  print_separator
  log_step "Reconfigurando wiring (hostnames Docker)"
  "${INSTALLER_ROOT}/setup-media-stack.sh" --yes || log_warn "Wiring parcial — revise nas UIs"

  echo
  log_ok "Migração concluída"
  compose ps
  print_final_urls
}

main "$@"
