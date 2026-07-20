#!/usr/bin/env bash
# services/qbittorrent.sh — Instalação e configuração do qBittorrent-nox
# shellcheck disable=SC2154

install_qbittorrent() {
  log_step "Instalando qBittorrent"
  export DEBIAN_FRONTEND=noninteractive

  apt-get install -y -qq qbittorrent-nox

  # Config do usuário alvo
  QBITTORRENT_CONFIG_DIR="${TARGET_HOME}/.config/qBittorrent"
  mkdir -p "${QBITTORRENT_CONFIG_DIR}"

  local conf="${QBITTORRENT_CONFIG_DIR}/qBittorrent.conf"
  local template="${INSTALLER_ROOT}/templates/qbittorrent.conf"

  if [[ ! -f "${conf}" ]]; then
    if [[ -f "${template}" ]]; then
      sed -e "s|__DOWNLOADS_DIR__|${DOWNLOADS_DIR}|g" \
          -e "s|__INCOMPLETE_DIR__|${INCOMPLETE_DIR}|g" \
          -e "s|__PORT__|${PORT_QBITTORRENT}|g" \
          -e "s|__MUSIC_ROOT__|${MUSIC_ROOT}|g" \
          "${template}" > "${conf}"
    else
      cat > "${conf}" <<EOF
[LegalNotice]
Accepted=true

[Preferences]
Connection\\PortRangeMin=6881
Downloads\\SavePath=${DOWNLOADS_DIR}
Downloads\\TempPath=${INCOMPLETE_DIR}
Downloads\\TempPathEnabled=true
WebUI\\Enabled=true
WebUI\\Address=*
WebUI\\Port=${PORT_QBITTORRENT}
WebUI\\LocalHostAuth=false
WebUI\\Username=admin
General\\Locale=pt_BR
EOF
    fi
  else
    # Atualizar paths sem destruir outras preferências
    if grep -q 'Downloads\\SavePath=' "${conf}"; then
      sed -i "s|Downloads\\\\SavePath=.*|Downloads\\\\SavePath=${DOWNLOADS_DIR}|" "${conf}"
    fi
    if grep -q 'Downloads\\TempPath=' "${conf}"; then
      sed -i "s|Downloads\\\\TempPath=.*|Downloads\\\\TempPath=${INCOMPLETE_DIR}|" "${conf}"
    fi
  fi

  chown -R "${TARGET_UID}:${TARGET_GID}" "${TARGET_HOME}/.config"
  chmod 600 "${conf}" 2>/dev/null || true

  # Unit systemd para o usuário
  local unit_src="${INSTALLER_ROOT}/templates/systemd/qbittorrent-nox.service"
  local unit_dst="/etc/systemd/system/qbittorrent-nox@${TARGET_USER}.service"

  if [[ -f "${unit_src}" ]]; then
    cp "${unit_src}" /etc/systemd/system/qbittorrent-nox@.service
  else
    cat > /etc/systemd/system/qbittorrent-nox@.service <<'EOF'
[Unit]
Description=qBittorrent-nox service for %i
After=network.target

[Service]
Type=simple
User=%i
Group=%i
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  fi

  # Aceitar EULA via LegalNotice (já no conf)
  mkdir -p "${DOWNLOADS_DIR}" "${INCOMPLETE_DIR}"
  case "${DISK_FSTYPE:-}" in
    ntfs|ntfs3|fuseblk|vfat|exfat)
      log_info "Pulando chown em ${MUSIC_ROOT} (filesystem ${DISK_FSTYPE})"
      ;;
    *)
      chown -R "${TARGET_UID}:${TARGET_GID}" "${MUSIC_ROOT}" 2>/dev/null \
        || log_warn "chown em ${MUSIC_ROOT} falhou"
      ;;
  esac

  systemctl daemon-reload
  systemctl enable "qbittorrent-nox@${TARGET_USER}" >/dev/null 2>&1 || true
  systemctl restart "qbittorrent-nox@${TARGET_USER}"

  if systemctl is-active --quiet "qbittorrent-nox@${TARGET_USER}"; then
    log_ok "qBittorrent ativo (WebUI porta ${PORT_QBITTORRENT})"
    wait_for_port "${PORT_QBITTORRENT}" 30 || log_warn "WebUI ainda não escuta na porta ${PORT_QBITTORRENT}"
    # Versões recentes geram senha temporária no journal
    local tmp_pass
    tmp_pass="$(journalctl -u "qbittorrent-nox@${TARGET_USER}" -n 80 --no-pager 2>/dev/null \
      | sed -n 's/.*temporary password as[: ]*//Ip;s/.*temporary password is[: ]*//Ip' \
      | awk '{print $1}' | tail -1 || true)"
    if [[ -n "${tmp_pass}" ]]; then
      log_info "Senha temporária do WebUI: ${tmp_pass} (usuário: admin)"
      mkdir -p "${STATE_DIR}"
      echo "${tmp_pass}" > "${STATE_DIR}/qbittorrent-temp-password.txt"
      chmod 600 "${STATE_DIR}/qbittorrent-temp-password.txt"
    else
      log_info "Login WebUI: admin — se a senha padrão não funcionar, veja: journalctl -u qbittorrent-nox@${TARGET_USER}"
    fi
  else
    log_warn "qBittorrent pode não ter iniciado — verifique: systemctl status qbittorrent-nox@${TARGET_USER}"
  fi

  log_ok "qBittorrent instalado"
}

update_qbittorrent() {
  log_step "Atualizando qBittorrent"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --only-upgrade qbittorrent-nox || log_warn "Sem atualização do qBittorrent"
  if [[ -n "${TARGET_USER:-}" ]]; then
    systemctl restart "qbittorrent-nox@${TARGET_USER}" 2>/dev/null || true
  fi
  log_ok "qBittorrent atualizado"
}

uninstall_qbittorrent() {
  log_step "Removendo qBittorrent"
  if [[ -n "${TARGET_USER:-}" ]]; then
    systemctl stop "qbittorrent-nox@${TARGET_USER}" 2>/dev/null || true
    systemctl disable "qbittorrent-nox@${TARGET_USER}" 2>/dev/null || true
  fi
  # Parar todas as instâncias template
  systemctl stop 'qbittorrent-nox@*' 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y -qq qbittorrent-nox 2>/dev/null || true
  rm -f /etc/systemd/system/qbittorrent-nox@.service
  systemctl daemon-reload
  log_warn "Config em ${QBITTORRENT_CONFIG_DIR:-~/.config/qBittorrent} preservada."
  log_ok "qBittorrent removido"
}
