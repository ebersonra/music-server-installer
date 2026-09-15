#!/usr/bin/env bash
# services/flaresolverr.sh — FlareSolverr via Docker Compose (ADR-0001)
# shellcheck disable=SC2154

# shellcheck source=services/docker.sh
source "${INSTALLER_ROOT}/services/docker.sh"

install_flaresolverr() {
  log_step "Instalando FlareSolverr (Docker)"
  ensure_docker
  write_compose_env
  _stop_native_unit flaresolverr
  # Remover bind nativo se ainda estiver no ar
  fuser -k "${PORT_FLARESOLVERR}/tcp" 2>/dev/null || true
  compose_up_service flaresolverr
  wait_compose_healthy flaresolverr "${PORT_FLARESOLVERR}" 60 || return 1
  validate_http "FlareSolverr" "http://127.0.0.1:${PORT_FLARESOLVERR}/" || return 1
  log_ok "FlareSolverr ativo (Docker) em 127.0.0.1:${PORT_FLARESOLVERR}"
}

update_flaresolverr() {
  log_step "Atualizando FlareSolverr (imagem estável)"
  ensure_docker
  compose_update_services flaresolverr
  wait_compose_healthy flaresolverr "${PORT_FLARESOLVERR}" 60 || return 1
  log_ok "FlareSolverr atualizado"
}

uninstall_flaresolverr() {
  log_step "Removendo FlareSolverr (Docker)"
  compose_down_service flaresolverr
  _stop_native_unit flaresolverr
  rm -f /etc/systemd/system/flaresolverr.service
  systemctl daemon-reload 2>/dev/null || true
  # Binário nativo legado
  rm -rf "${FLARESOLVERR_DIR:-/opt/flaresolverr}"
  log_ok "FlareSolverr removido"
}
