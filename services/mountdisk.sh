#!/usr/bin/env bash
# services/mountdisk.sh — Montagem NTFS/disco e fstab (seguro)
# shellcheck disable=SC2154

FSTAB_MARKER="# music-server-installer"
# Impede udisks/desktop de remontar o volume com user_id=0/default_permissions
UDISKS_NO_AUTOMOUNT_RULE="/etc/udev/rules.d/99-music-server-installer-no-automount.rules"

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

# FUSE/NTFS morto: findmnt ainda lista, mas stat/ls falham com
# "Ponto final de transporte não está conectado" / ENOTCONN
mount_point_is_stale() {
  local mp="$1"
  local err
  if ! findmnt -n "${mp}" &>/dev/null; then
    return 1
  fi
  err="$(stat "${mp}" 2>&1 >/dev/null || true)"
  if [[ "${err}" == *"Transport endpoint is not connected"* ]] || \
     [[ "${err}" == *"Ponto final de transporte"* ]] || \
     [[ "${err}" == *"Não está conectado"* ]]; then
    return 0
  fi
  # Device sumiu mas findmnt ainda aponta
  local src
  src="$(findmnt -n -o SOURCE "${mp}" 2>/dev/null | awk '{print $1}')"
  if [[ -n "${src}" && ! -b "${src}" && ! -e "${src}" ]]; then
    return 0
  fi
  return 1
}

clear_stale_mount_point() {
  local mp="$1"
  if ! findmnt -n "${mp}" &>/dev/null && [[ -d "${mp}" ]]; then
    return 0
  fi
  if mount_point_is_stale "${mp}"; then
    local src
    src="$(findmnt -n -o SOURCE "${mp}" 2>/dev/null | awk '{print $1}' || true)"
    log_warn "Mount morto/fantasma em ${mp}${src:+ (${src})} — desmontando (lazy)"
    umount -l "${mp}" 2>/dev/null || umount "${mp}" 2>/dev/null \
      || die "Não foi possível limpar mount morto em ${mp}. Tente: sudo ./reset-mount.sh"
    # Aguardar o kernel liberar o dentry
    local i
    for i in 1 2 3 4 5; do
      if ! findmnt -n "${mp}" &>/dev/null && stat "${mp}" &>/dev/null; then
        break
      fi
      if ! findmnt -n "${mp}" &>/dev/null; then
        # diretório pode não existir ainda — ok
        break
      fi
      sleep 0.4
    done
    log_ok "Mount morto removido de ${mp}"
  fi
}

# Desmonta e espera findmnt limpar (evita umount -l + corrida com udisks)
force_umount_clean() {
  local mp="$1"
  local i
  if ! findmnt -n "${mp}" &>/dev/null; then
    return 0
  fi
  umount "${mp}" 2>/dev/null || true
  for i in 1 2 3 4 5; do
    if ! findmnt -n "${mp}" &>/dev/null; then
      return 0
    fi
    sleep 0.3
  done
  umount -l "${mp}" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! findmnt -n "${mp}" &>/dev/null; then
      return 0
    fi
    sleep 0.3
  done
  return 1
}

# systemd media-*.automount (GVFS/udisks também cria às vezes)
suppress_systemd_automount() {
  local mp="$1"
  local base unit
  base="${mp##*/}"
  [[ -z "${base}" || "${base}" == "/" || "${mp}" == "/" ]] && return 0
  unit="media-${base}.automount"
  if systemctl cat "${unit}" &>/dev/null; then
    systemctl stop "${unit}" 2>/dev/null || true
    systemctl disable "${unit}" 2>/dev/null || true
    systemctl mask "${unit}" 2>/dev/null || true
    log_info "Automount systemd ${unit} parado/mascarado"
  fi
}

# Regra udev: udisks não automonta este UUID (elimina corrida em /media/*)
install_udisks_no_automount_rule() {
  local uuid="$1"
  [[ -n "${uuid}" ]] || return 0

  mkdir -p "$(dirname "${UDISKS_NO_AUTOMOUNT_RULE}")"
  local tmp
  tmp="$(mktemp)"
  {
    echo "# ${FSTAB_MARKER} — impede automount do desktop (udisks) neste volume"
    if [[ -f "${UDISKS_NO_AUTOMOUNT_RULE}" ]]; then
      # Preserva outras UUIDs já gerenciadas (exceto a atual, reescrita abaixo)
      grep -E '^ENV\{ID_FS_UUID\}==' "${UDISKS_NO_AUTOMOUNT_RULE}" 2>/dev/null \
        | grep -vF "\"${uuid}\"" || true
    fi
    echo "ENV{ID_FS_UUID}==\"${uuid}\", ENV{UDISKS_AUTO}=\"0\", ENV{UDISKS_PRESENTATION_NOPOLICY}=\"1\""
  } > "${tmp}"

  if [[ -f "${UDISKS_NO_AUTOMOUNT_RULE}" ]] && cmp -s "${tmp}" "${UDISKS_NO_AUTOMOUNT_RULE}"; then
    rm -f "${tmp}"
    return 0
  fi
  mv "${tmp}" "${UDISKS_NO_AUTOMOUNT_RULE}"
  chmod 644 "${UDISKS_NO_AUTOMOUNT_RULE}"
  log_ok "Regra udev: sem automount udisks para UUID=${uuid}"

  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
  fi
}

remove_udisks_no_automount_rule() {
  if [[ -f "${UDISKS_NO_AUTOMOUNT_RULE}" ]]; then
    rm -f "${UDISKS_NO_AUTOMOUNT_RULE}"
    if command -v udevadm >/dev/null 2>&1; then
      udevadm control --reload-rules 2>/dev/null || true
      udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
    fi
    log_ok "Regra udev de no-automount removida"
  fi
}

# Para automount + desmonta mounts concorrentes do mesmo device (desktop)
suppress_desktop_interference() {
  local device="$1"
  local mp="$2"
  local uuid other

  uuid="$(blkid -s UUID -o value "${device}" 2>/dev/null || true)"
  [[ -z "${uuid}" && -n "${DISK_UUID:-}" ]] && uuid="${DISK_UUID}"

  suppress_systemd_automount "${mp}"
  install_udisks_no_automount_rule "${uuid}"

  while IFS= read -r other; do
    [[ -z "${other}" || "${other}" == "${mp}" ]] && continue
    if declare -f is_critical_mount_point >/dev/null && is_critical_mount_point "${other}"; then
      log_warn "Mount concorrente em path crítico ignorado: ${other}"
      continue
    fi
    log_warn "Desmontando mount concorrente do desktop: ${other}"
    force_umount_clean "${other}" || true
  done < <(findmnt -n -o TARGET -S "${device}" 2>/dev/null || true)

  if command -v udisksctl >/dev/null 2>&1; then
    udisksctl unmount -b "${device}" 2>/dev/null || true
  fi
}

# true se arquivos no NTFS aparecem como TARGET_UID (uid= do ntfs-3g).
# NÃO use findmnt OPTIONS: fuseblk sempre mostra user_id=0,group_id=0,default_permissions
# quando root monta — isso é o dono da conexão FUSE, não o uid= do volume.
ntfs_mount_has_expected_owner() {
  local mp="$1"
  local st_uid
  [[ -n "${TARGET_UID:-}" ]] || return 1
  findmnt -n "${mp}" &>/dev/null || return 1
  st_uid="$(stat -c '%u' "${mp}" 2>/dev/null || echo "")"
  [[ "${st_uid}" == "${TARGET_UID}" ]]
}

# Log diagnóstico: FUSE options vs ownership real vs cmdline ntfs-3g
ntfs_log_mount_diagnostics() {
  local mp="$1"
  local st_uid opts procs
  st_uid="$(stat -c '%u' "${mp}" 2>/dev/null || echo '?')"
  opts="$(findmnt -n -o OPTIONS "${mp}" 2>/dev/null || echo '?')"
  procs="$(pgrep -a 'ntfs-3g|mount.ntfs' 2>/dev/null | grep -F "${mp}" || echo '(nenhum ntfs-3g neste path)')"
  log_info "Diagnóstico NTFS ${mp}: stat_uid=${st_uid} (esperado ${TARGET_UID:-?})"
  log_info "  findmnt (FUSE, user_id=0 é normal se root montou): ${opts}"
  log_info "  processo: ${procs}"
}

# Volume NTFS sujo após crash/reboot abrupt — ntfs-3g pode montar sem aplicar uid como esperado
ntfs_warn_if_dirty() {
  local device="$1"
  local vol_info
  if command -v ntfsinfo >/dev/null 2>&1; then
    vol_info="$(ntfsinfo -m "${device}" 2>/dev/null || true)"
    if [[ "${vol_info}" == *[Dd]irty* ]] || [[ "${vol_info}" == *"VOLUME DIRTY"* ]]; then
      log_warn "Volume NTFS marcado como DIRTY (reboot abrupt?). Considere:"
      log_warn "  sudo ntfsfix -n ${device}   # só checagem"
      log_warn "  Ou no Windows: chkdsk /f neste disco"
    fi
  fi
}

# Monta NTFS e exige ownership real via stat (não via OPTIONS do FUSE)
mount_ntfs_with_ownership() {
  local device="$1"
  local mp="$2"
  local opts="$3"
  local actual_type=""
  local st_uid=""

  actual_type="$(blkid -s TYPE -o value "${device}" 2>/dev/null || true)"
  if [[ -n "${actual_type}" && "${actual_type}" != "ntfs" && "${actual_type}" != "ntfs3" && "${actual_type}" != "fuseblk" ]]; then
    die "Device ${device} não é NTFS (type=${actual_type}). O path /dev/sdX provavelmente mudou após reboot.
Rode: sudo ./mount.sh -i   # ou reconecte o HD e: sudo ./mount.sh"
  fi

  ntfs_warn_if_dirty "${device}"
  suppress_desktop_interference "${device}" "${mp}"
  if findmnt -n "${mp}" &>/dev/null; then
    force_umount_clean "${mp}" \
      || die "Não foi possível liberar ${mp} antes de montar NTFS"
  fi

  log_info "Montando NTFS: ntfs-3g -o ${opts}"
  if command -v ntfs-3g >/dev/null 2>&1; then
    if ntfs-3g -o "${opts}" "${device}" "${mp}"; then
      # Pequena espera: FUSE às vezes atrasa o dentry
      sleep 0.2
      if ntfs_mount_has_expected_owner "${mp}"; then
        return 0
      fi
      st_uid="$(stat -c '%u' "${mp}" 2>/dev/null || echo '?')"
      ntfs_log_mount_diagnostics "${mp}"
      log_warn "ntfs-3g retornou OK mas stat uid=${st_uid} (esperado ${TARGET_UID})"
      force_umount_clean "${mp}" || true
    else
      log_warn "ntfs-3g direto falhou — tentando mount -t ntfs-3g"
      ntfs_warn_if_dirty "${device}"
    fi
  fi
  if mount -t ntfs-3g -o "${opts}" "${device}" "${mp}"; then
    sleep 0.2
    if ntfs_mount_has_expected_owner "${mp}"; then
      return 0
    fi
    st_uid="$(stat -c '%u' "${mp}" 2>/dev/null || echo '?')"
    ntfs_log_mount_diagnostics "${mp}"
    log_warn "mount -t ntfs-3g OK mas stat uid=${st_uid} (esperado ${TARGET_UID})"
    force_umount_clean "${mp}" || true
  fi
  # Fallback kernel ntfs3
  local uid gid
  uid="$(echo "${opts}" | sed -n 's/.*uid=\([0-9]*\).*/\1/p')"
  gid="$(echo "${opts}" | sed -n 's/.*gid=\([0-9]*\).*/\1/p')"
  if mount -t ntfs3 -o "uid=${uid},gid=${gid},umask=002" "${device}" "${mp}"; then
    sleep 0.2
    if ntfs_mount_has_expected_owner "${mp}"; then
      return 0
    fi
    force_umount_clean "${mp}" || true
  fi
  die "Falha ao montar ${device} em ${mp} com uid=${TARGET_UID} (type=${actual_type:-desconhecido}).
stat_uid=$(stat -c '%u' "${mp}" 2>/dev/null || echo 'não montado')
Opções FUSE (user_id=0 é normal): $(findmnt -n -o OPTIONS "${mp}" 2>/dev/null || echo 'não montado')
Se reboot abrupt: sudo ntfsfix -n ${device}  ou chkdsk no Windows
Mount fantasma: sudo ./reset-mount.sh && sudo ./mount.sh"
}

# Remonta até ownership correta ou esgota tentativas (corrida udisks)
ensure_ntfs_ownership() {
  local device="$1"
  local mp="$2"
  local opts="$3"
  local attempt

  for attempt in 1 2 3; do
    if ntfs_mount_has_expected_owner "${mp}"; then
      # Janela curta: desktop pode sobrescrever logo após o mount
      sleep 0.6
      if ntfs_mount_has_expected_owner "${mp}"; then
        return 0
      fi
      log_warn "Ownership mudou após mount — possível interferência do desktop (tentativa ${attempt}/3)"
      ntfs_log_mount_diagnostics "${mp}"
    else
      log_warn "Pós-mount: ownership ainda errada — forçando remount ntfs-3g (tentativa ${attempt}/3)"
      if findmnt -n "${mp}" &>/dev/null; then
        ntfs_log_mount_diagnostics "${mp}"
      fi
    fi
    suppress_desktop_interference "${device}" "${mp}"
    force_umount_clean "${mp}" \
      || die "Não foi possível desmontar para corrigir ownership"
    mount_ntfs_with_ownership "${device}" "${mp}" "${opts}"
  done

  if ! ntfs_mount_has_expected_owner "${mp}"; then
    ntfs_log_mount_diagnostics "${mp}"
    die "NTFS montado sem ownership uid=${TARGET_UID} (stat=$(stat -c '%u' "${mp}" 2>/dev/null || echo '?')).
Nota: findmnt mostrando user_id=0/default_permissions é NORMAL no FUSE — o critério é o stat.
Tente: sudo ./reset-mount.sh && sudo ./mount.sh
Volume sujo após crash: sudo ntfsfix -n ${device}  ou chkdsk no Windows"
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

  # Limpar mount FUSE/NTFS morto ANTES do mkdir (senão: "Ponto final de transporte não está conectado")
  clear_stale_mount_point "${MOUNT_POINT}"

  mkdir -p "${MOUNT_POINT}"

  [[ -n "${TARGET_UID:-}" ]] || die "TARGET_UID vazio — selecione o usuário antes de montar"
  local media_gid
  media_gid="$(getent group media | cut -d: -f3)"
  [[ -n "${media_gid}" ]] || die "Grupo 'media' sem GID"
  local ntfs_opts="uid=${TARGET_UID},gid=${media_gid},umask=002,windows_names"

  # Antecipar: parar automount/udisks antes de qualquer umount/mount
  case "${DISK_FSTYPE}" in
    ntfs|ntfs3|fuseblk)
      suppress_desktop_interference "${DISK_DEVICE}" "${MOUNT_POINT}"
      ;;
  esac

  # Já montado neste ponto?
  if findmnt -n "${MOUNT_POINT}" &>/dev/null; then
    local current_dev current_uuid disk_uuid
    current_dev="$(findmnt -n -o SOURCE "${MOUNT_POINT}" | awk '{print $1}')"
    current_uuid="$(findmnt -n -o UUID "${MOUNT_POINT}" 2>/dev/null || true)"
    disk_uuid="$(blkid -s UUID -o value "${DISK_DEVICE}" 2>/dev/null || true)"

    # Mount fantasma: /dev/sdb1 someu após o USB reenumerar como /dev/sdc1
    if [[ ! -b "${current_dev}" ]]; then
      log_warn "Mount fantasma em ${MOUNT_POINT} (device inexistente: ${current_dev})"
      force_umount_clean "${MOUNT_POINT}" \
        || die "Não foi possível desmontar mount fantasma ${MOUNT_POINT}"
      log_ok "Mount fantasma removido"
    elif mount_point_is_stale "${MOUNT_POINT}"; then
      log_warn "Mount FUSE morto em ${MOUNT_POINT} (transport endpoint disconnected)"
      force_umount_clean "${MOUNT_POINT}" \
        || die "Não foi possível desmontar mount morto ${MOUNT_POINT}"
      log_ok "Mount morto removido"
    elif [[ "${current_dev}" == "${DISK_DEVICE}" ]] || \
         [[ -n "${current_uuid}" && -n "${disk_uuid}" && "${current_uuid}" == "${disk_uuid}" ]]; then
      # ntfs-3g: remount NÃO aplica uid/gid — precisa umount + mount
      if ! ntfs_mount_has_expected_owner "${MOUNT_POINT}"; then
        log_warn "Disco montado sem uid=${TARGET_UID}/gid=media — remontando com permissões corretas"
        force_umount_clean "${MOUNT_POINT}" \
          || die "Falha ao desmontar ${MOUNT_POINT} para corrigir ownership"
      else
        log_ok "Disco já montado em ${MOUNT_POINT} (uid=${TARGET_UID}, gid=media)"
      fi
    else
      # Mesmo disco sob outro /dev (sdb → sdc)
      local current_blkid_uuid
      current_blkid_uuid="$(blkid -s UUID -o value "${current_dev}" 2>/dev/null || true)"
      if [[ -n "${disk_uuid}" && -n "${current_blkid_uuid}" && "${disk_uuid}" == "${current_blkid_uuid}" ]]; then
        log_warn "Mesmo disco sob nome diferente (${current_dev} → ${DISK_DEVICE})"
        force_umount_clean "${MOUNT_POINT}" \
          || die "Falha ao desmontar ${MOUNT_POINT}"
        log_ok "Desmontado para remontar como ${DISK_DEVICE}"
      else
        log_warn "Ponto de montagem ${MOUNT_POINT} em uso por ${current_dev}"
        if confirm "Desmontar ${current_dev} e montar ${DISK_DEVICE} em ${MOUNT_POINT}?"; then
          force_umount_clean "${MOUNT_POINT}" \
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
        force_umount_clean "${existing_mp}" || die "Falha ao desmontar ${existing_mp}"
      else
        MOUNT_POINT="${existing_mp}"
        MUSIC_ROOT="${MOUNT_POINT}/Musicas"
        log_warn "Reutilizando ${MOUNT_POINT} — fstab NÃO será alterado"
        MANAGE_FSTAB=false
        if ! ntfs_mount_has_expected_owner "${MOUNT_POINT}"; then
          log_warn "Ownership incorreta em ${MOUNT_POINT} — desmontando para remontar com uid/gid"
          force_umount_clean "${MOUNT_POINT}" \
            || die "Falha ao desmontar ${MOUNT_POINT}"
        else
          log_ok "Permissões NTFS ok em ${MOUNT_POINT} (uid=${TARGET_UID}, gid=media)"
        fi
      fi
    fi

    # Montar se ainda não estiver montado (MANAGE_FSTAB só controla fstab)
    if ! findmnt -n "${MOUNT_POINT}" &>/dev/null; then
      case "${DISK_FSTYPE}" in
        ntfs|ntfs3|fuseblk)
          mount_ntfs_with_ownership "${DISK_DEVICE}" "${MOUNT_POINT}" "${ntfs_opts}"
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

  # Garantia final: NTFS deve mapear para o usuário do instalador (retry vs udisks)
  case "${DISK_FSTYPE}" in
    ntfs|ntfs3|fuseblk)
      ensure_ntfs_ownership "${DISK_DEVICE}" "${MOUNT_POINT}" "${ntfs_opts}"
      log_ok "NTFS com ownership uid=${TARGET_UID} gid=${media_gid} (grupo media)"
      ;;
  esac

  # A partir daqui: apenas gestão de fstab (MANAGE_FSTAB / críticos)
  if [[ "${MANAGE_FSTAB:-true}" == "false" ]]; then
    log_info "Pulando fstab (MANAGE_FSTAB=false)"
    return 0
  fi

  # /media/*: com regra UDISKS_AUTO=0 o fstab deixa de conflitar com o desktop
  if [[ "${MOUNT_POINT}" == /media/* ]]; then
    local disk_uuid_for_rule
    disk_uuid_for_rule="$(blkid -s UUID -o value "${DISK_DEVICE}" 2>/dev/null || true)"
    [[ -z "${disk_uuid_for_rule}" && -n "${DISK_UUID:-}" ]] && disk_uuid_for_rule="${DISK_UUID}"
    install_udisks_no_automount_rule "${disk_uuid_for_rule}"
    log_info "Ponto em /media/* — fstab será gerenciado (udisks automount desativado para este UUID)"
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
  elif fstab_remove_installer_entries; then
    log_ok "Entradas do instalador removidas do fstab"
  else
    log_warn "Não foi possível remover entradas do fstab com segurança"
  fi
  remove_udisks_no_automount_rule
}
