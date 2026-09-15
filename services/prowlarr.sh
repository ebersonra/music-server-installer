#!/usr/bin/env bash
# services/prowlarr.sh — Prowlarr via Docker Compose (ADR-0001)
# shellcheck disable=SC2154

# shellcheck source=services/docker.sh
source "${INSTALLER_ROOT}/services/docker.sh"

install_prowlarr() {
  log_step "Instalando Prowlarr (Docker)"
  ensure_docker
  write_compose_env
  _stop_native_unit prowlarr
  fuser -k "${PORT_PROWLARR}/tcp" 2>/dev/null || true
  rm -f "${PROWLARR_CONFIG_DIR}/prowlarr.pid" 2>/dev/null || true
  chown -R "${TARGET_UID}:$(_media_gid)" "${PROWLARR_CONFIG_DIR}" 2>/dev/null || true

  compose_up_service prowlarr
  wait_compose_healthy prowlarr "${PORT_PROWLARR}" 90 || return 1
  validate_http "Prowlarr" "http://127.0.0.1:${PORT_PROWLARR}/ping" || return 1
  log_ok "Prowlarr ativo (Docker) na porta ${PORT_PROWLARR}"
}

update_prowlarr() {
  log_step "Atualizando Prowlarr (imagem estável)"
  ensure_docker
  compose_update_services prowlarr
  wait_compose_healthy prowlarr "${PORT_PROWLARR}" 90 || return 1
  log_ok "Prowlarr atualizado"
}

uninstall_prowlarr() {
  log_step "Removendo Prowlarr (Docker)"
  compose_down_service prowlarr
  _stop_native_unit prowlarr
  rm -f /etc/systemd/system/prowlarr.service
  systemctl daemon-reload 2>/dev/null || true
  rm -rf /opt/Prowlarr
  log_ok "Prowlarr removido"
}
