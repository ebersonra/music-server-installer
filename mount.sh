#!/usr/bin/env bash
# mount.sh — Remonta o disco da biblioteca (sem reinstalar serviços)
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Se /dev/sdX mudou após reboot, resolve pelo UUID do fstab/estado
resolve_disk_device() {
  local device="${DISK_DEVICE:-}"
  local uuid=""

  if [[ -n "${device}" && -b "${device}" ]]; then
    return 0
  fi

  # UUID da entrada do instalador no fstab
  if [[ -f /etc/fstab ]]; then
    uuid="$(awk -v marker="${FSTAB_MARKER:-# music-server-installer}" '
      index($0, marker) == 1 { getline; if ($1 ~ /^UUID=/) { sub(/^UUID=/, "", $1); print $1; exit } }
    ' /etc/fstab 2>/dev/null || true)"
  fi

  # Fallback: UUID do device antigo (se ainda existir no blkid cache) ou label
  if [[ -z "${uuid}" && -n "${device}" ]]; then
    uuid="$(blkid -s UUID -o value "${device}" 2>/dev/null || true)"
  fi

  if [[ -n "${uuid}" ]]; then
    local by_uuid="/dev/disk/by-uuid/${uuid}"
    if [[ -b "${by_uuid}" || -L "${by_uuid}" ]]; then
      DISK_DEVICE="$(readlink -f "${by_uuid}")"
      log_ok "Disco resolvido por UUID → ${DISK_DEVICE}"
      # Atualiza fstype se possível
      local ft
      ft="$(blkid -s TYPE -o value "${DISK_DEVICE}" 2>/dev/null || true)"
      [[ -n "${ft}" ]] && DISK_FSTYPE="${ft}"
      return 0
    fi
  fi

  # Label conhecido (ex.: SAMSUNG)
  if [[ -n "${DISK_LABEL:-}" && "${DISK_LABEL}" != "local" ]]; then
    local by_label="/dev/disk/by-label/${DISK_LABEL}"
    if [[ -e "${by_label}" ]]; then
      DISK_DEVICE="$(readlink -f "${by_label}")"
      log_ok "Disco resolvido por label ${DISK_LABEL} → ${DISK_DEVICE}"
      local ft
      ft="$(blkid -s TYPE -o value "${DISK_DEVICE}" 2>/dev/null || true)"
      [[ -n "${ft}" ]] && DISK_FSTYPE="${ft}"
      return 0
    fi
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
