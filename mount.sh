#!/usr/bin/env bash
# mount.sh — Remonta o disco da biblioteca (sem reinstalar serviços)
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"
# shellcheck source=services/mountdisk.sh
source "${INSTALLER_ROOT}/services/mountdisk.sh"

INTERACTIVE=false
SKIP_FSTAB=false
CREATE_FOLDERS=true

usage() {
  cat <<EOF
Uso: sudo ./mount.sh [opções]

Remonta o disco da biblioteca de músicas sem rodar install/update.

Opções:
  -i, --interactive   Escolher disco de novo (ignora device do estado)
  --skip-fstab        Não alterar /etc/fstab
  --no-folders        Não recriar pastas Artistas/Downloads
  -y, --yes           Confirmar automaticamente
  -h, --help          Mostrar esta ajuda

Exemplos:
  sudo ./mount.sh
  sudo ./mount.sh -i
  sudo ./mount.sh -y
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--interactive) INTERACTIVE=true; shift ;;
      --skip-fstab) SKIP_FSTAB=true; shift ;;
      --no-folders) CREATE_FOLDERS=false; shift ;;
      -y|--yes) ASSUME_YES=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

# Atualiza DISK_* a partir de um device já resolvido (não apaga valores se blkid falhar)
_refresh_disk_from_device() {
  local cand="$1"
  local probed_uuid="" probed_ft="" probed_lab=""
  DISK_DEVICE="$(readlink -f "${cand}")"
  probed_uuid="$(blkid -s UUID -o value "${DISK_DEVICE}" 2>/dev/null || true)"
  probed_ft="$(blkid -s TYPE -o value "${DISK_DEVICE}" 2>/dev/null || true)"
  probed_lab="$(blkid -s LABEL -o value "${DISK_DEVICE}" 2>/dev/null || true)"
  # Fallback lsblk (às vezes blkid precisa de root em NTFS)
  if [[ -z "${probed_uuid}" || -z "${probed_ft}" || -z "${probed_lab}" ]]; then
    local lsblk_line
    lsblk_line="$(lsblk -n -o UUID,FSTYPE,LABEL "${DISK_DEVICE}" 2>/dev/null | head -n1 || true)"
    if [[ -n "${lsblk_line}" ]]; then
      [[ -z "${probed_uuid}" ]] && probed_uuid="$(awk '{print $1}' <<<"${lsblk_line}")"
      [[ -z "${probed_ft}" ]] && probed_ft="$(awk '{print $2}' <<<"${lsblk_line}")"
      [[ -z "${probed_lab}" ]] && probed_lab="$(awk '{print $3}' <<<"${lsblk_line}")"
    fi
  fi
  if [[ -n "${probed_uuid}" && "${probed_uuid}" != "-" ]]; then
    DISK_UUID="${probed_uuid}"
  fi
  if [[ -n "${probed_ft}" && "${probed_ft}" != "-" ]]; then
    DISK_FSTYPE="${probed_ft}"
  fi
  if [[ -n "${probed_lab}" && "${probed_lab}" != "-" ]]; then
    DISK_LABEL="${probed_lab}"
  fi
  return 0
}

# true se o path ainda é o disco de dados esperado (nunca confiar só em /dev/sdX)
_device_matches_expected_disk() {
  local cand="$1"
  local expected_uuid="${2:-}"
  local expected_label="${3:-}"
  local cand_uuid cand_label cand_type

  [[ -b "${cand}" ]] || return 1

  cand_uuid="$(blkid -s UUID -o value "${cand}" 2>/dev/null || true)"
  cand_label="$(blkid -s LABEL -o value "${cand}" 2>/dev/null || true)"
  cand_type="$(blkid -s TYPE -o value "${cand}" 2>/dev/null || true)"

  # swap / sem FS / FS não usável = path reaproveitado (ex.: sdb1 virou swap do SO)
  [[ -n "${cand_type}" ]] || return 1
  is_usable_data_fstype "${cand_type}" || return 1

  if [[ -n "${expected_uuid}" && -n "${cand_uuid}" && "${cand_uuid}" != "${expected_uuid}" ]]; then
    return 1
  fi
  if [[ -n "${expected_label}" && "${expected_label}" != "local" && -n "${cand_label}" && "${cand_label}" != "${expected_label}" ]]; then
    return 1
  fi
  return 0
}

# UUID do disco: estado → fstab (ativo ou comentado) → blkid do path antigo só se label bater
_lookup_disk_uuid() {
  local uuid="${DISK_UUID:-}"
  local device="${DISK_DEVICE:-}"
  local expected_label="${DISK_LABEL:-}"

  if [[ -n "${uuid}" ]]; then
    printf '%s\n' "${uuid}"
    return 0
  fi

  if [[ -f /etc/fstab ]]; then
    uuid="$(awk -v marker="${FSTAB_MARKER:-# music-server-installer}" '
      index($0, marker) == 1 { getline; if ($1 ~ /^UUID=/) { sub(/^UUID=/, "", $1); print $1; exit } }
    ' /etc/fstab 2>/dev/null || true)"

    # reset-mount.sh comenta a linha; ainda dá para recuperar o UUID pelo mount point
    if [[ -z "${uuid}" && -n "${MOUNT_POINT:-}" ]]; then
      uuid="$(awk -v mp="${MOUNT_POINT}" '
        {
          line = $0
          sub(/^[[:space:]]*#+[[:space:]]*/, "", line)
          if (line !~ /^UUID=/) next
          n = split(line, f, /[[:space:]]+/)
          if (n >= 2 && f[2] == mp) {
            sub(/^UUID=/, "", f[1])
            print f[1]
            exit
          }
        }
      ' /etc/fstab 2>/dev/null || true)"
    fi
  fi

  # Só use blkid do path antigo se o label ainda for o esperado (evita UUID do swap)
  if [[ -z "${uuid}" && -n "${device}" && -b "${device}" ]]; then
    local old_label
    old_label="$(blkid -s LABEL -o value "${device}" 2>/dev/null || true)"
    if [[ -n "${expected_label}" && "${expected_label}" != "local" && "${old_label}" == "${expected_label}" ]]; then
      uuid="$(blkid -s UUID -o value "${device}" 2>/dev/null || true)"
    fi
  fi

  printf '%s\n' "${uuid}"
}

# Se /dev/sdX mudou após reboot, resolve por UUID/label — nunca confiar só no path
resolve_disk_device() {
  local device="${DISK_DEVICE:-}"
  local expected_label="${DISK_LABEL:-}"
  local uuid=""
  local by_uuid by_label actual_type

  uuid="$(_lookup_disk_uuid)"
  DISK_UUID="${uuid}"

  # 1) UUID estável (by-uuid)
  if [[ -n "${uuid}" ]]; then
    by_uuid="/dev/disk/by-uuid/${uuid}"
    if [[ -e "${by_uuid}" ]]; then
      _refresh_disk_from_device "${by_uuid}"
      if [[ "${DISK_DEVICE}" != "${device}" && -n "${device}" ]]; then
        log_ok "Disco resolvido por UUID (${device} → ${DISK_DEVICE})"
      else
        log_ok "Disco resolvido por UUID → ${DISK_DEVICE}"
      fi
      return 0
    fi
  fi

  # 2) Label conhecido (ex.: SAMSUNG)
  if [[ -n "${expected_label}" && "${expected_label}" != "local" ]]; then
    by_label="/dev/disk/by-label/${expected_label}"
    if [[ -e "${by_label}" ]]; then
      _refresh_disk_from_device "${by_label}"
      if [[ "${DISK_DEVICE}" != "${device}" && -n "${device}" ]]; then
        log_ok "Disco resolvido por label ${expected_label} (${device} → ${DISK_DEVICE})"
      else
        log_ok "Disco resolvido por label ${expected_label} → ${DISK_DEVICE}"
      fi
      return 0
    fi
  fi

  # 3) Path do estado só se ainda for o mesmo disco de dados
  if [[ -n "${device}" && -b "${device}" ]] && \
     _device_matches_expected_disk "${device}" "${uuid}" "${expected_label}"; then
    _refresh_disk_from_device "${device}"
    return 0
  fi

  if [[ -n "${device}" && -b "${device}" ]]; then
    actual_type="$(blkid -s TYPE -o value "${device}" 2>/dev/null || echo "?")"
    log_warn "Path antigo ${device} não é mais o disco da biblioteca (type=${actual_type}, esperado label=${expected_label:-?} uuid=${uuid:-?})"
  fi

  return 1
}

show_status() {
  echo
  echo -e "${C_BOLD}Status${C_RESET}"
  echo -e "  Disco:      ${DISK_LABEL:-?} (${DISK_DEVICE})"
  echo -e "  Fstype:     ${DISK_FSTYPE:-?}"
  echo -e "  Montagem:   ${MOUNT_POINT}"
  echo -e "  Biblioteca: ${MUSIC_ROOT}"
  if findmnt -n "${MOUNT_POINT}" &>/dev/null; then
    echo -e "  Estado:     ${C_GREEN}montado${C_RESET} ($(findmnt -n -o SOURCE,FSTYPE "${MOUNT_POINT}"))"
  else
    echo -e "  Estado:     ${C_YELLOW}desmontado${C_RESET}"
  fi
  echo
}

main() {
  parse_args "$@"
  require_root
  print_banner

  echo -e "${C_BOLD}Remontagem do disco${C_RESET}"
  echo

  local have_state=false
  if load_state; then
    have_state=true
    log_ok "Estado carregado de ${STATE_FILE}"
  else
    log_warn "Sem estado prévio (${STATE_FILE})"
  fi

  if [[ "${INTERACTIVE}" == "true" ]] || [[ "${have_state}" != "true" ]]; then
    print_separator
    select_disk
    if [[ -z "${TARGET_USER:-}" ]]; then
      print_separator
      select_user
    else
      TARGET_UID="$(id -u "${TARGET_USER}")"
      TARGET_GID="$(id -g "${TARGET_USER}")"
      TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
    fi
  else
    # Recarregar uid/gid do usuário salvo
    if ! id "${TARGET_USER}" &>/dev/null; then
      die "Usuário do estado não existe mais: ${TARGET_USER}"
    fi
    TARGET_UID="$(id -u "${TARGET_USER}")"
    TARGET_GID="$(id -g "${TARGET_USER}")"
    TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"

    if [[ "${DISK_DEVICE}" == "local" ]]; then
      log_ok "Modo local — nada a montar"
      MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
      show_status
      exit 0
    fi

    if ! resolve_disk_device; then
      log_warn "Device ${DISK_DEVICE:-?} indisponível (USB reenumerou?)"
      echo
      if confirm "Escolher disco interativamente?"; then
        select_disk
      else
        die "Conecte o HD e rode: sudo ./mount.sh"
      fi
    fi
  fi

  MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
  DOWNLOADS_DIR="${DOWNLOADS_DIR:-${MUSIC_ROOT}/Downloads}"
  INCOMPLETE_DIR="${INCOMPLETE_DIR:-${MUSIC_ROOT}/Downloads/Incomplete}"

  show_status

  if ! confirm "Remontar agora?"; then
    die "Cancelado."
  fi

  if [[ "${SKIP_FSTAB}" == "true" ]]; then
    MANAGE_FSTAB=false
  fi

  ensure_media_group
  configure_ntfs_mount

  if [[ "${CREATE_FOLDERS}" == "true" ]]; then
    create_music_folders
  fi

  # Atualiza device no estado (letra pode ter mudado)
  if [[ "${have_state}" == "true" ]] || [[ -f "${STATE_FILE}" ]]; then
    save_state
  fi

  show_status
  log_ok "Disco pronto"
  echo -e "${C_DIM}Serviços não foram reinstalados. Se Lidarr/Plex não veem a pasta, reinicie-os:${C_RESET}"
  echo -e "${C_DIM}  sudo systemctl restart lidarr plexmediaserver 'qbittorrent-nox@${TARGET_USER}'${C_RESET}"
  echo
}

main "$@"
