#!/usr/bin/env bash
# services/plex.sh — Plex Media Server via Docker Compose (ADR-0001)
# shellcheck disable=SC2154

# shellcheck source=services/docker.sh
source "${INSTALLER_ROOT}/services/docker.sh"

_safe_media_symlink() {
  local target="$1"
  local link_path="$2"

  mkdir -p /media
  if [[ -L "${link_path}" ]]; then
    ln -sfn "${target}" "${link_path}"
    chown -h "${TARGET_UID}:${TARGET_GID}" "${link_path}" 2>/dev/null || true
  elif [[ -d "${link_path}" ]]; then
    log_warn "${link_path} já é um diretório — use ${target} diretamente no Plex"
  elif [[ -e "${link_path}" ]]; then
    log_warn "${link_path} existe e não é symlink/diretório — pulando atalho"
  else
    ln -sfn "${target}" "${link_path}" || log_warn "Não foi possível criar ${link_path} → ${target}"
    chown -h "${TARGET_UID}:${TARGET_GID}" "${link_path}" 2>/dev/null || true
  fi
}

ensure_openssh_sftp() {
  export DEBIAN_FRONTEND=noninteractive
  if ! dpkg -l openssh-server 2>/dev/null | grep -q '^ii'; then
    apt-get install -y -qq openssh-server
  fi
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
  if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    log_ok "OpenSSH/SFTP pronto (FolderSync → ${PHOTOS_ROOT:-fotos})"
  else
    log_warn "OpenSSH instalado, mas ssh/sshd não está ativo"
  fi
}

_plex_library_hints() {
  mkdir -p "${STATE_DIR}"
  cat > "${STATE_DIR}/plex-library-hint.txt" <<EOF
Bibliotecas Plex sugeridas:

1) Músicas
  Nome: ${PLEX_LIBRARY_NAME}
  Tipo: Music
  Pasta: ${MUSIC_ROOT}

2) Fotos (HD externo)
  Nome: ${PLEX_PHOTOS_LIBRARY_NAME}
  Tipo: Photos
  Pasta: ${PHOTOS_ROOT}

Após o primeiro acesso em http://$(get_local_ip):${PORT_PLEX}/web,
adicione as bibliotecas apontando para as pastas acima.

Sync do celular (FolderSync / SFTP):
  sftp://$(get_local_ip) → ${PHOTOS_ROOT}/Camera (WhatsApp, Screenshots, …)
  O Plex detecta fotos novas automaticamente.
EOF
}

install_plex() {
  log_step "Instalando Plex (Docker)"
  ensure_docker
  write_compose_env

  if [[ -d "${MUSIC_ROOT}" ]]; then
    if [[ "${PLEX_LIBRARY_NAME}" == *"/"* || -z "${PLEX_LIBRARY_NAME}" ]]; then
      die "Nome de biblioteca Plex inválido: ${PLEX_LIBRARY_NAME}"
    fi
    if [[ "${MUSIC_ROOT}" != "/media/${PLEX_LIBRARY_NAME}" ]]; then
      _safe_media_symlink "${MUSIC_ROOT}" "/media/${PLEX_LIBRARY_NAME}"
    fi
  fi

  PHOTOS_ROOT="${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}"
  PLEX_PHOTOS_LIBRARY_NAME="${PLEX_PHOTOS_LIBRARY_NAME:-Fotos}"
  if [[ -d "${PHOTOS_ROOT}" ]]; then
    if [[ "${PLEX_PHOTOS_LIBRARY_NAME}" == *"/"* || -z "${PLEX_PHOTOS_LIBRARY_NAME}" ]]; then
      die "Nome de biblioteca Plex Photos inválido: ${PLEX_PHOTOS_LIBRARY_NAME}"
    fi
    if [[ "${PHOTOS_ROOT}" != "/media/${PLEX_PHOTOS_LIBRARY_NAME}" ]]; then
      _safe_media_symlink "${PHOTOS_ROOT}" "/media/${PLEX_PHOTOS_LIBRARY_NAME}"
    fi
  fi

  ensure_openssh_sftp

  _stop_native_unit plexmediaserver
  fuser -k "${PORT_PLEX}/tcp" 2>/dev/null || true
  # Evitar chown -R em bibliotecas grandes (pode levar minutos); o s6 do LinuxServer
  # ajusta o necessário no start com PUID/PGID.
  chown "${TARGET_UID}:$(_media_gid)" "${PLEX_CONFIG_DIR}" 2>/dev/null || true

  compose_up_service plex
  wait_compose_healthy plex "${PORT_PLEX}" 120 || log_warn "Plex instalado, mas a porta ${PORT_PLEX} ainda não respondeu"
  validate_http "Plex" "http://127.0.0.1:${PORT_PLEX}/identity" 15 || log_warn "Plex ainda inicializando"
  _plex_library_hints
  log_ok "Plex ativo (Docker) — músicas: ${MUSIC_ROOT} · fotos: ${PHOTOS_ROOT}"
}

update_plex() {
  log_step "Atualizando Plex (imagem estável)"
  ensure_docker
  compose_update_services plex
  wait_compose_healthy plex "${PORT_PLEX}" 120 || true
  log_ok "Plex atualizado"
}

uninstall_plex() {
  log_step "Removendo Plex (Docker)"
  compose_down_service plex
  _stop_native_unit plexmediaserver
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y -qq plexmediaserver 2>/dev/null || true
  apt-get purge -y -qq plexmediaserver 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/plexmediaserver.list
  rm -f /usr/share/keyrings/plex-archive-keyring.gpg
  [[ -L "/media/${PLEX_LIBRARY_NAME:-Músicas}" ]] && rm -f "/media/${PLEX_LIBRARY_NAME:-Músicas}"
  [[ -L "/media/${PLEX_PHOTOS_LIBRARY_NAME:-Fotos}" ]] && rm -f "/media/${PLEX_PHOTOS_LIBRARY_NAME:-Fotos}"
  log_warn "Dados em ${PLEX_CONFIG_DIR} preservados. Remova manualmente se desejar."
  log_warn "Músicas e fotos no HD externo NÃO foram apagadas."
  log_ok "Plex removido"
}
