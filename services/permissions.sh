#!/usr/bin/env bash
# services/permissions.sh — Permissões e grupos para os serviços
# shellcheck disable=SC2154

ensure_media_group_early() {
  if ! getent group media >/dev/null; then
    groupadd --system media
    log_ok "Grupo 'media' criado"
  fi
  if [[ -n "${TARGET_USER:-}" ]]; then
    usermod -aG media "${TARGET_USER}" 2>/dev/null || true
  fi
}

_safe_chown_music() {
  local owner="$1"
  if [[ ! -d "${MUSIC_ROOT}" ]]; then
    return 0
  fi
  case "${DISK_FSTYPE:-}" in
    ntfs|ntfs3|fuseblk|vfat|exfat)
      # Ownership vem das opções de mount (uid/gid) — chown costuma falhar
      log_info "Filesystem ${DISK_FSTYPE}: permissões via mount (gid=media); pulando chown/chmod recursivo"
      return 0
      ;;
  esac
  if ! chown -R "${owner}" "${MUSIC_ROOT}" 2>/dev/null; then
    log_warn "chown em ${MUSIC_ROOT} falhou (filesystem pode não suportá-lo)"
  fi
  if ! chmod -R u+rwX,g+rwX,o+rX "${MUSIC_ROOT}" 2>/dev/null; then
    log_warn "chmod em ${MUSIC_ROOT} falhou"
  fi
  find "${MUSIC_ROOT}" -type d -exec chmod g+s {} \; 2>/dev/null || true
}

configure_permissions() {
  log_step "Configurando permissões"

  ensure_media_group_early

  # Usuários de serviço no grupo media + grupo do usuário alvo (acesso cruzado)
  for svc_user in plex lidarr prowlarr; do
    if id "${svc_user}" &>/dev/null; then
      usermod -aG media "${svc_user}" 2>/dev/null || true
      if [[ -n "${TARGET_USER:-}" ]]; then
        usermod -aG "${TARGET_USER}" "${svc_user}" 2>/dev/null || true
      fi
    fi
  done

  if [[ -d "${MUSIC_ROOT}" ]]; then
    _safe_chown_music "${TARGET_UID}:media"

    if command -v setfacl &>/dev/null; then
      if ! setfacl -R -m g:media:rwX "${MUSIC_ROOT}" 2>/dev/null; then
        case "${DISK_FSTYPE:-}" in
          ntfs|ntfs3|fuseblk|vfat|exfat)
            : # esperado
            ;;
          *)
            log_warn "setfacl falhou em ${MUSIC_ROOT} — verifique permissões do grupo media"
            ;;
        esac
      else
        setfacl -R -d -m g:media:rwX "${MUSIC_ROOT}" 2>/dev/null || true
      fi
    fi
  fi

  if [[ -d "${PHOTOS_ROOT:-}" ]]; then
    case "${DISK_FSTYPE:-}" in
      ntfs|ntfs3|fuseblk|vfat|exfat)
        log_info "Filesystem ${DISK_FSTYPE}: pulando chown em ${PHOTOS_ROOT}"
        ;;
      *)
        chown -R "${TARGET_UID}:media" "${PHOTOS_ROOT}" 2>/dev/null || true
        chmod -R u+rwX,g+rwX,o+rX "${PHOTOS_ROOT}" 2>/dev/null || true
        ;;
    esac
  fi

  # TARGET_USER também no grupo de cada serviço
  for svc_user in plex lidarr prowlarr; do
    if id "${svc_user}" &>/dev/null; then
      local svc_group
      svc_group="$(id -gn "${svc_user}")"
      usermod -aG "${svc_group}" "${TARGET_USER}" 2>/dev/null || true
    fi
  done

  log_ok "Permissões configuradas"
}

reapply_media_group() {
  ensure_media_group_early
  for svc_user in plex lidarr prowlarr; do
    if id "${svc_user}" &>/dev/null; then
      usermod -aG media "${svc_user}" 2>/dev/null || true
      [[ -n "${TARGET_USER:-}" ]] && usermod -aG "${TARGET_USER}" "${svc_user}" 2>/dev/null || true
    fi
  done
  _safe_chown_music "${TARGET_UID}:media"
  if [[ -d "${PHOTOS_ROOT:-}" ]]; then
    case "${DISK_FSTYPE:-}" in
      ntfs|ntfs3|fuseblk|vfat|exfat) ;;
      *) chown -R "${TARGET_UID}:media" "${PHOTOS_ROOT}" 2>/dev/null || true ;;
    esac
  fi
}
