#!/usr/bin/env bash
# services/lidarr.sh — Lidarr via Docker Compose (ADR-0001)
# shellcheck disable=SC2154

# shellcheck source=services/docker.sh
source "${INSTALLER_ROOT}/services/docker.sh"

install_lidarr() {
  log_step "Instalando Lidarr (Docker)"
  ensure_docker
  write_compose_env
  _stop_native_unit lidarr
  fuser -k "${PORT_LIDARR}/tcp" 2>/dev/null || true
  rm -f "${LIDARR_CONFIG_DIR}/lidarr.pid" 2>/dev/null || true
  chown -R "${TARGET_UID}:$(_media_gid)" "${LIDARR_CONFIG_DIR}" 2>/dev/null || true

  compose_up_service lidarr
  wait_compose_healthy lidarr "${PORT_LIDARR}" 120 || return 1
  validate_http "Lidarr" "http://127.0.0.1:${PORT_LIDARR}/ping" || return 1
  log_ok "Lidarr ativo (Docker) na porta ${PORT_LIDARR}"
}

update_lidarr() {
  log_step "Atualizando Lidarr (imagem estável)"
  ensure_docker
  compose_update_services lidarr
  wait_compose_healthy lidarr "${PORT_LIDARR}" 120 || return 1
  log_ok "Lidarr atualizado"
}

uninstall_lidarr() {
  log_step "Removendo Lidarr (Docker)"
  compose_down_service lidarr
  _stop_native_unit lidarr
  rm -f /etc/systemd/system/lidarr.service
  systemctl daemon-reload 2>/dev/null || true
  rm -rf /opt/Lidarr
  log_ok "Lidarr removido"
}
