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
  local c resolved
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

  # Resolver symlinks / path canônico (evita bypass: /mnt/x → /)
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath -m -- "${mp}" 2>/dev/null || true)"
  else
    resolved="$(readlink -f -- "${mp}" 2>/dev/null || true)"
  fi
  if [[ -n "${resolved}" && "${resolved}" != "${mp}" ]]; then
    resolved="${resolved%/}"
    [[ -z "${resolved}" ]] && resolved="/"
    for c in "${CRITICAL_MOUNT_POINTS[@]}"; do
      [[ "${resolved}" == "${c}" ]] && return 0
    done
    case "${resolved}" in
      /home/*|/var/*|/usr/*|/etc/*|/boot/*|/snap/*|/run/*)
        return 0
        ;;
    esac
  fi
  return 1
}

validate_mount_point() {
  local mp="$1"
  local resolved=""

  if [[ -z "${mp}" ]]; then
    die "Ponto de montagem vazio."
  fi
  if [[ "${mp}" != /* ]]; then
    die "Ponto de montagem deve ser caminho absoluto: ${mp}"
  fi
  if [[ "${mp}" =~ [[:space:]] ]]; then
    die "Ponto de montagem não pode conter espaços: ${mp}"
  fi
  if [[ "${mp}" == *..* ]]; then
    die "Ponto de montagem inválido: ${mp}"
  fi

  if is_critical_mount_point "${mp}"; then
    die "Ponto de montagem crítico/protegido não permitido: ${mp}"
  fi

  # Dupla checagem explícita do destino canônico (mensagem mais clara)
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath -m -- "${mp}" 2>/dev/null || true)"
  else
    resolved="$(readlink -f -- "${mp}" 2>/dev/null || true)"
  fi
  if [[ -n "${resolved}" ]] && is_critical_mount_point "${resolved}"; then
    die "Ponto de montagem resolve para path crítico (${mp} → ${resolved})"
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
  if grep -qF "${FSTAB_MARKER}" /etc/fstab 2>/dev/null; then
    if ! fstab_remove_installer_entries; then
      die "Falha ao limpar entradas anteriores do instalador no fstab — abortando para não duplicar/corromper"
    fi
  fi

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
    current_dev="$(findmnt -n -o SOURCE "${MOUNT_POINT}" | awk '{print $1}')"
    current_uuid="$(findmnt -n -o UUID "${MOUNT_POINT}" 2>/dev/null || true)"
    disk_uuid="$(blkid -s UUID -o value "${DISK_DEVICE}" 2>/dev/null || true)"

    # Mount fantasma: /dev/sdb1 someu após o USB reenumerar como /dev/sdc1
    if [[ ! -b "${current_dev}" ]]; then
      log_warn "Mount fantasma em ${MOUNT_POINT} (device inexistente: ${current_dev})"
      umount "${MOUNT_POINT}" 2>/dev/null || umount -l "${MOUNT_POINT}" \
        || die "Não foi possível desmontar mount fantasma ${MOUNT_POINT}"
      log_ok "Mount fantasma removido"
    elif [[ "${current_dev}" == "${DISK_DEVICE}" ]] || \
         [[ -n "${current_uuid}" && -n "${disk_uuid}" && "${current_uuid}" == "${disk_uuid}" ]]; then
      log_ok "Disco já montado em ${MOUNT_POINT}"
      case "${DISK_FSTYPE}" in
        ntfs|ntfs3|fuseblk)
          mount -o "remount,${ntfs_opts}" "${MOUNT_POINT}" 2>/dev/null \
            || log_warn "Não foi possível remount com gid=media — permissões NTFS podem ficar limitadas"
          ;;
      esac
    else
      # Mesmo disco sob outro /dev (sdb → sdc)
      local current_blkid_uuid
      current_blkid_uuid="$(blkid -s UUID -o value "${current_dev}" 2>/dev/null || true)"
      if [[ -n "${disk_uuid}" && -n "${current_blkid_uuid}" && "${disk_uuid}" == "${current_blkid_uuid}" ]]; then
        log_warn "Mesmo disco sob nome diferente (${current_dev} → ${DISK_DEVICE})"
        umount "${MOUNT_POINT}" 2>/dev/null || umount -l "${MOUNT_POINT}" \
          || die "Falha ao desmontar ${MOUNT_POINT}"
        log_ok "Desmontado para remontar como ${DISK_DEVICE}"
      else
        log_warn "Ponto de montagem ${MOUNT_POINT} em uso por ${current_dev}"
        if confirm "Desmontar ${current_dev} e montar ${DISK_DEVICE} em ${MOUNT_POINT}?"; then
          umount "${MOUNT_POINT}" 2>/dev/null || umount -l "${MOUNT_POINT}" \
            || die "Falha ao desmontar ${MOUNT_POINT}"
        else
          die "Ponto de montagem ${MOUNT_POINT} já está em uso por ${current_dev}"
        fi
      fi
    fi
  fi

  if ! findmnt -n "${MOUNT_POINT}" &>/dev/null; then
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
        case "${DISK_FSTYPE}" in
          ntfs|ntfs3|fuseblk)
            if ! mount -o "remount,${ntfs_opts}" "${MOUNT_POINT}" 2>/dev/null; then
              log_warn "Remount com gid=media falhou em ${MOUNT_POINT}"
              log_warn "Lidarr/Plex podem não escrever na biblioteca até remontar com opções corretas"
            else
              log_ok "Remount aplicado em ${MOUNT_POINT} com gid=media"
            fi
            ;;
        esac
      fi
    fi

    # Montar se ainda não estiver montado (MANAGE_FSTAB só controla fstab)
    if ! findmnt -n "${MOUNT_POINT}" &>/dev/null; then
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

  # A partir daqui: apenas gestão de fstab (MANAGE_FSTAB /media / críticos)
  if [[ "${MANAGE_FSTAB:-true}" == "false" ]]; then
    log_info "Pulando fstab (MANAGE_FSTAB=false)"
    return 0
  fi

  # Mounts do desktop (/media/...) são frágeis — nunca gravar no fstab
  if [[ "${MOUNT_POINT}" == /media/* ]]; then
    log_warn "Mount em ${MOUNT_POINT} (udisks/desktop) — fstab NÃO será alterado"
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
