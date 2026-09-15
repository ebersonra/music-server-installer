#!/usr/bin/env bash
# services/qbittorrent.sh — qBittorrent via Docker Compose (ADR-0001)
# shellcheck disable=SC2154

# shellcheck source=services/docker.sh
source "${INSTALLER_ROOT}/services/docker.sh"

_qbit_apply_excluded_file_names() {
  local conf="$1"
  local names="${QBIT_EXCLUDED_FILE_NAMES}"
  [[ -f "${conf}" ]] || return 0
  if grep -q '^Session\\ExcludedFileNames=' "${conf}" 2>/dev/null; then
    sed -i "s|^Session\\\\ExcludedFileNames=.*|Session\\\\ExcludedFileNames=${names}|" "${conf}"
  else
    # Seção BitTorrent
    if grep -q '^\[BitTorrent\]' "${conf}"; then
      sed -i "/^\[BitTorrent\]/a Session\\\\ExcludedFileNamesEnabled=true\nSession\\\\ExcludedFileNames=${names}" "${conf}"
    fi
  fi
  if ! grep -q 'ExcludedFileNamesEnabled=true' "${conf}"; then
    sed -i 's|^Session\\ExcludedFileNamesEnabled=.*|Session\\ExcludedFileNamesEnabled=true|' "${conf}" || true
  fi
}

_seed_qbittorrent_config() {
  local conf_dir="${QBITTORRENT_CONFIG_DIR}/qBittorrent"
  local conf="${conf_dir}/qBittorrent.conf"
  mkdir -p "${conf_dir}"
  if [[ ! -f "${conf}" ]]; then
    local tmpl="${INSTALLER_ROOT}/templates/qbittorrent.conf"
    if [[ -f "${tmpl}" ]]; then
      sed -e "s|__DOWNLOADS_DIR__|${DOWNLOADS_DIR}|g" \
          -e "s|__INCOMPLETE_DIR__|${INCOMPLETE_DIR}|g" \
          -e "s|__PORT__|${PORT_QBITTORRENT}|g" \
          -e "s|__EXCLUDED_FILE_NAMES__|${QBIT_EXCLUDED_FILE_NAMES}|g" \
          "${tmpl}" > "${conf}"
    fi
  else
    _qbit_apply_excluded_file_names "${conf}"
  fi
  chown -R "${TARGET_UID}:${TARGET_GID}" "${QBITTORRENT_CONFIG_DIR}" 2>/dev/null || true
}

install_qbittorrent() {
  log_step "Instalando qBittorrent (Docker)"
  ensure_docker
  write_compose_env
  _seed_qbittorrent_config

  # Units nativas (template @user e instâncias)
  _stop_native_unit "qbittorrent-nox@${TARGET_USER}"
  _stop_native_unit qbittorrent-nox
  systemctl disable "qbittorrent-nox@${TARGET_USER}" 2>/dev/null || true
  fuser -k "${PORT_QBITTORRENT}/tcp" 2>/dev/null || true

  compose_up_service qbittorrent
  wait_compose_healthy qbittorrent "${PORT_QBITTORRENT}" 90 || return 1
  validate_http "qBittorrent" "http://127.0.0.1:${PORT_QBITTORRENT}/" || return 1
  log_ok "qBittorrent ativo (Docker) na porta ${PORT_QBITTORRENT}"
  log_info "Senha WebUI: veja 'docker logs music-qbittorrent' no primeiro start (LinuxServer)"
}

update_qbittorrent() {
  log_step "Atualizando qBittorrent (imagem estável)"
  ensure_docker
  write_compose_env
  _seed_qbittorrent_config
  compose_update_services qbittorrent
  wait_compose_healthy qbittorrent "${PORT_QBITTORRENT}" 90 || return 1
  log_ok "qBittorrent atualizado"
}

uninstall_qbittorrent() {
  log_step "Removendo qBittorrent (Docker)"
  compose_down_service qbittorrent
  _stop_native_unit "qbittorrent-nox@${TARGET_USER:-}"
  _stop_native_unit qbittorrent-nox
  rm -f /etc/systemd/system/qbittorrent-nox@.service
  systemctl daemon-reload 2>/dev/null || true
  log_ok "qBittorrent removido"
}
