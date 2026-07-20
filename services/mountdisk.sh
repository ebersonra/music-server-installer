#!/usr/bin/env bash
# services/mountdisk.sh — Montagem NTFS/disco e fstab (seguro)
# shellcheck disable=SC2154

FSTAB_MARKER="# music-server-installer"

# Paths que nunca podem ser usados como MOUNT_POINT gerenciado
CRITICAL_MOUNT_POINTS=(
  / /boot /boot/efi /efi /home /var /usr /etc /opt /root /tmp /srv
  /bin /sbin /lib /lib64 /dev /proc /sys /run /snap
)

is_critical_mount_point() {
  local mp="$1"
  local c
  mp="${mp%/}"
  [[ -z "${mp}" ]] && mp="/"
  for c in "${CRITICAL_MOUNT_POINTS[@]}"; do
    [[ "${mp}" == "${c}" ]] && return 0
  done
  case "${mp}" in
    /home/*|/var/*|/usr/*|/etc/*|/boot/*|/snap/*|/run/*)
      return 0
      ;;
  esac
  return 1
}

validate_mount_point() {
  local mp="$1"

  if [[ -z "${mp}" ]]; then
    die "Ponto de montagem vazio."
  fi
  if [[ "${mp}" != /* ]]; then
    die "Ponto de montagem deve ser caminho absoluto: ${mp}"
  fi
  if [[ "${mp}" =~ [[:space:]] ]]; then
    die "Ponto de montagem não pode conter espaços: ${mp}"
  fi
  # Bloquear path traversal e caracteres estranhos
  if [[ "${mp}" == *..* ]]; then
    die "Ponto de montagem inválido: ${mp}"
  fi
  if is_critical_mount_point "${mp}"; then
    die "Ponto de montagem crítico/protegido não permitido: ${mp}"
  fi
}

ensure_media_group() {
  if ! getent group media >/dev/null; then
    groupadd --system media
    log_ok "Grupo 'media' criado"
  fi
  MEDIA_GID="$(getent group media | cut -d: -f3)"
  if [[ -n "${TARGET_USER:-}" ]]; then
    usermod -aG media "${TARGET_USER}" 2>/dev/null || true
  fi
}

# Remove apenas linhas marcadas pelo instalador
fstab_remove_installer_entries() {
  if [[ ! -f /etc/fstab ]]; then
    return 0
  fi
  if ! grep -qF "${FSTAB_MARKER}" /etc/fstab 2>/dev/null; then
    return 1
  fi

  cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"

  local tmp
  tmp="$(mktemp)"
  awk -v marker="${FSTAB_MARKER}" '
    index($0, marker) == 1 { skip=1; next }
    skip { skip=0; next }
    { print }
  ' /etc/fstab > "${tmp}"

  if [[ ! -s "${tmp}" ]]; then
    log_error "Abortando: fstab temporário ficou vazio"
    rm -f "${tmp}"
    return 1
  fi
  if ! awk 'BEGIN{f=0} /^[[:space:]]*#/{next} NF>=2 && $2=="/"{f=1} END{exit !f}' "${tmp}"; then
    log_error "Abortando: fstab temporário sem montagem de / — restaurando backup"
    rm -f "${tmp}"
    return 1
  fi

  mv "${tmp}" /etc/fstab
  return 0
}

fstab_add_installer_entry() {
  local uuid="$1"
  local mount_point="$2"
  local fstype="$3"
  local options="$4"
  local pass="${5:-0}"

  validate_mount_point "${mount_point}"

  # Remover entrada anterior deste instalador
  fstab_remove_installer_entries || true

  # Se já existe linha NÃO nossa para este UUID ou mount, não sobrescrever
  if grep -vF "${FSTAB_MARKER}" /etc/fstab 2>/dev/null | grep -qF "UUID=${uuid}"; then
    log_warn "UUID=${uuid} já existe no fstab (não gerenciado). Não alterando."
    return 0
  fi
  # Match fixo por campo de mount (coluna 2) sem regex no path
  if awk -v mp="${mount_point}" '
    /^[[:space:]]*#/ { next }
    NF>=2 && $2==mp { found=1 }
    END { exit !found }
  ' /etc/fstab 2>/dev/null; then
    log_warn "Mount ${mount_point} já existe no fstab (não gerenciado). Não alterando."
    return 0
  fi

  {
    echo "${FSTAB_MARKER}"
    echo "UUID=${uuid} ${mount_point} ${fstype} ${options} 0 ${pass}"
  } >> /etc/fstab

  log_ok "Entrada fstab adicionada (marcada: music-server-installer)"
}

configure_ntfs_mount() {
  log_step "Configurando NTFS / montagem do disco"

  ensure_media_group

  if [[ "${DISK_DEVICE}" == "local" || -z "${DISK_DEVICE}" ]]; then
    log_ok "Modo local — sem montagem de disco externo"
    mkdir -p "${MUSIC_ROOT}"
    return 0
  fi

  if [[ ! -b "${DISK_DEVICE}" ]]; then
    die "Dispositivo de bloco inválido: ${DISK_DEVICE}"
  fi

  validate_mount_point "${MOUNT_POINT}"
  mkdir -p "${MOUNT_POINT}"

  local media_gid
  media_gid="$(getent group media | cut -d: -f3)"
  local ntfs_opts="uid=${TARGET_UID},gid=${media_gid},umask=002,windows_names"

  # Já montado neste ponto?
  if findmnt -n "${MOUNT_POINT}" &>/dev/null; then
    local current_dev current_uuid disk_uuid
    current_dev="$(findmnt -n -o SOURCE "${MOUNT_POINT}")"
    current_uuid="$(findmnt -n -o UUID "${MOUNT_POINT}" 2>/dev/null || true)"
    disk_uuid="$(blkid -s UUID -o value "${DISK_DEVICE}" 2>/dev/null || true)"
    if [[ "${current_dev}" == "${DISK_DEVICE}" ]] || \
       [[ -n "${current_uuid}" && "${current_uuid}" == "${disk_uuid}" ]]; then
      log_ok "Disco já montado em ${MOUNT_POINT}"
      case "${DISK_FSTYPE}" in
        ntfs|ntfs3|fuseblk)
          mount -o "remount,${ntfs_opts}" "${MOUNT_POINT}" 2>/dev/null \
            || log_warn "Não foi possível remount com gid=media — permissões NTFS podem ficar limitadas"
          ;;
      esac
    else
      die "Ponto de montagem ${MOUNT_POINT} já está em uso por ${current_dev}"
    fi
  else
    # Disco montado em outro lugar (ex.: /media/$USER/LABEL)?
    local existing_mp
    existing_mp="$(findmnt -n -o TARGET "${DISK_DEVICE}" 2>/dev/null || true)"
    if [[ -n "${existing_mp}" && "${existing_mp}" != "${MOUNT_POINT}" ]]; then
      log_warn "Disco já montado em ${existing_mp}"
      if is_critical_mount_point "${existing_mp}"; then
        die "Disco está montado em path crítico (${existing_mp}). Escolha outro disco."
      fi
      if confirm "Desmontar e remontar em ${MOUNT_POINT} com permissões do instalador?"; then
        umount "${existing_mp}" || die "Falha ao desmontar ${existing_mp}"
      else
        MOUNT_POINT="${existing_mp}"
        MUSIC_ROOT="${MOUNT_POINT}/Musicas"
        log_warn "Reutilizando ${MOUNT_POINT} — fstab NÃO será alterado"
        MANAGE_FSTAB=false
      fi
    fi

    if [[ "${MANAGE_FSTAB:-true}" != "false" ]] && ! findmnt -n "${MOUNT_POINT}" &>/dev/null; then
      case "${DISK_FSTYPE}" in
        ntfs|ntfs3|fuseblk)
          if ! mount -t ntfs-3g -o "${ntfs_opts}" "${DISK_DEVICE}" "${MOUNT_POINT}"; then
            mount -t ntfs3 -o "uid=${TARGET_UID},gid=${media_gid},umask=002" "${DISK_DEVICE}" "${MOUNT_POINT}" \
              || die "Falha ao montar ${DISK_DEVICE} em ${MOUNT_POINT}"
          fi
          ;;
        ext4|ext3|xfs|btrfs)
          mount "${DISK_DEVICE}" "${MOUNT_POINT}" || die "Falha ao montar ${DISK_DEVICE}"
          chown "${TARGET_UID}:media" "${MOUNT_POINT}" 2>/dev/null || true
          ;;
        vfat|exfat)
          mount -o "uid=${TARGET_UID},gid=${media_gid},umask=002" "${DISK_DEVICE}" "${MOUNT_POINT}" \
            || die "Falha ao montar ${DISK_DEVICE}"
          ;;
        *)
          mount "${DISK_DEVICE}" "${MOUNT_POINT}" || die "Falha ao montar ${DISK_DEVICE} (fstype=${DISK_FSTYPE})"
          ;;
      esac
      log_ok "Montado ${DISK_DEVICE} → ${MOUNT_POINT}"
    fi
  fi

  if [[ "${MANAGE_FSTAB:-true}" == "false" ]]; then
    return 0
  fi

  # Não gerenciar fstab se o mount atual é path crítico
  if is_critical_mount_point "${MOUNT_POINT}"; then
    log_warn "Mount em path protegido — fstab não será alterado"
    return 0
  fi

  local uuid
  uuid="$(blkid -s UUID -o value "${DISK_DEVICE}" 2>/dev/null || true)"

  if [[ -z "${uuid}" ]]; then
    log_warn "UUID não encontrado para ${DISK_DEVICE}; fstab não atualizado"
    return 0
  fi

  local fstab_fstype fstab_opts fstab_pass
  case "${DISK_FSTYPE}" in
    ntfs|ntfs3|fuseblk)
      fstab_fstype="ntfs-3g"
      fstab_opts="${ntfs_opts},defaults,nofail"
      fstab_pass=0
      ;;
    vfat|exfat)
      fstab_fstype="${DISK_FSTYPE}"
      fstab_opts="uid=${TARGET_UID},gid=${media_gid},umask=002,defaults,nofail"
      fstab_pass=0
      ;;
    *)
      fstab_fstype="${DISK_FSTYPE}"
      fstab_opts="defaults,nofail"
      fstab_pass=2
      ;;
  esac

  fstab_add_installer_entry "${uuid}" "${MOUNT_POINT}" "${fstab_fstype}" "${fstab_opts}" "${fstab_pass}"

  if ! findmnt --verify --tab-file /etc/fstab &>/dev/null; then
    log_warn "Validação do fstab retornou avisos — verifique /etc/fstab manualmente"
  fi
}

# Usado pelo uninstall — remove só entradas com nosso marcador
remove_installer_fstab() {
  if [[ ! -f /etc/fstab ]]; then
    return 0
  fi
  if ! grep -qF "${FSTAB_MARKER}" /etc/fstab; then
    log_warn "Nenhuma entrada music-server-installer no fstab"
    return 0
  fi
  if fstab_remove_installer_entries; then
    log_ok "Entradas do instalador removidas do fstab"
  else
    log_warn "Não foi possível remover entradas do fstab com segurança"
  fi
}
