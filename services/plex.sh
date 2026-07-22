#!/usr/bin/env bash
# services/plex.sh — Instalação e configuração do Plex Media Server
# shellcheck disable=SC2154

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

install_plex() {
  log_step "Instalando Plex"

  if systemctl is-active --quiet plexmediaserver 2>/dev/null || dpkg -l plexmediaserver &>/dev/null; then
    log_ok "Plex já instalado — atualizando se disponível"
  fi

  export DEBIAN_FRONTEND=noninteractive

  # Método preferencial: repositório oficial Plex
  if [[ ! -f /etc/apt/sources.list.d/plexmediaserver.list ]]; then
    curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key \
      | gpg --dearmor -o /usr/share/keyrings/plex-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/plex-archive-keyring.gpg] https://downloads.plex.tv/repo/deb public main" \
      > /etc/apt/sources.list.d/plexmediaserver.list
    apt-get update -qq
  fi

  if ! apt-get install -y -qq plexmediaserver; then
    log_warn "Falha via repositório — tentando pacote .deb direto"
    if [[ "${OS_ARCH}" != "amd64" && "${OS_ARCH}" != "x86_64" ]]; then
      die "Fallback .deb do Plex só está configurado para amd64 (arch=${OS_ARCH}). Instale manualmente ou use o repositório oficial."
    fi
    local tmp_deb
    tmp_deb="$(mktemp /tmp/plex-XXXXXX.deb)"
    local deb_url="${PLEX_DEB_URL}"
    if ! curl -fsSL -o "${tmp_deb}" "${deb_url}"; then
      rm -f "${tmp_deb}"
      die "Não foi possível baixar o Plex Media Server"
    fi
    if ! apt-get install -y -qq "${tmp_deb}" && ! dpkg -i "${tmp_deb}"; then
      rm -f "${tmp_deb}"
      die "Falha ao instalar o pacote Plex (.deb)"
    fi
    apt-get install -f -y -qq || true
    rm -f "${tmp_deb}"
  fi

  if ! dpkg -l plexmediaserver 2>/dev/null | grep -q '^ii'; then
    die "Plex Media Server não está instalado após tentativas de instalação"
  fi

  # Adicionar plex ao grupo media e usuário
  if id plex &>/dev/null; then
    usermod -aG media plex 2>/dev/null || true
    usermod -aG "${TARGET_USER}" plex 2>/dev/null || true
  fi

  # Atalhos estáveis sob /media/<nome> só se MUSIC/PHOTOS não estiverem já em /media/...
  # Paths reais deste setup: /media/music/Musicas e /media/music/Fotos
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

  # SFTP para sync do celular (FolderSync) → pastas no HD
  ensure_openssh_sftp

  service_enable_start plexmediaserver

  if ! wait_for_port "${PORT_PLEX}" 45; then
    log_warn "Plex instalado, mas a porta ${PORT_PLEX} ainda não respondeu"
  fi

  # Nota: criação automática da biblioteca exige claim token; documentamos o caminho
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

  log_ok "Plex instalado — músicas: ${MUSIC_ROOT} · fotos: ${PHOTOS_ROOT}"
}

update_plex() {
  log_step "Atualizando Plex"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --only-upgrade plexmediaserver || log_warn "Nenhuma atualização do Plex disponível"
  systemctl restart plexmediaserver 2>/dev/null || true
  log_ok "Plex atualizado"
}

uninstall_plex() {
  log_step "Removendo Plex"
  systemctl stop plexmediaserver 2>/dev/null || true
  systemctl disable plexmediaserver 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y -qq plexmediaserver 2>/dev/null || true
  apt-get purge -y -qq plexmediaserver 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/plexmediaserver.list
  rm -f /usr/share/keyrings/plex-archive-keyring.gpg
  [[ -L "/media/${PLEX_LIBRARY_NAME:-Músicas}" ]] && rm -f "/media/${PLEX_LIBRARY_NAME:-Músicas}"
  [[ -L "/media/${PLEX_PHOTOS_LIBRARY_NAME:-Fotos}" ]] && rm -f "/media/${PLEX_PHOTOS_LIBRARY_NAME:-Fotos}"
  # NÃO remove /var/lib/plexmediaserver por padrão (dados do usuário)
  log_warn "Dados em ${PLEX_CONFIG_DIR} preservados. Remova manualmente se desejar."
  log_warn "Músicas e fotos no HD externo NÃO foram apagadas."
  log_ok "Plex removido"
}
