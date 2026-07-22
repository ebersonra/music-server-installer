#!/usr/bin/env bash
# backup-restic.sh — Snapshot criptografado (restic) de músicas/fotos
# Uso:
#   sudo ./backup-restic.sh
#   sudo ./backup-restic.sh --dry-run
#   sudo ./backup-restic.sh --prune-only
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"

RESTIC_CONF="${STATE_DIR}/restic-backup.conf"
DRY_RUN=false
PRUNE_ONLY=false

usage() {
  cat <<EOF
Uso: sudo ./backup-restic.sh [opções]

Cria snapshot criptografado (restic) de /media/music/Musicas e Fotos.

Opções:
  --dry-run       Simula (restic com --dry-run onde suportado)
  --prune-only    Só aplica retenção (forget + prune)
  -h, --help      Esta ajuda

Configure antes: sudo ./setup-security.sh  (ou só a parte restic)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --prune-only) PRUNE_ONLY=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

load_restic_conf() {
  if [[ ! -f "${RESTIC_CONF}" ]]; then
    die "Config não encontrada: ${RESTIC_CONF}
Execute: sudo ./setup-security.sh"
  fi
  # shellcheck source=/dev/null
  source "${RESTIC_CONF}"

  [[ -n "${RESTIC_REPOSITORY:-}" ]] || die "RESTIC_REPOSITORY vazio em ${RESTIC_CONF}"
  [[ -f "${RESTIC_PASSWORD_FILE:-}" ]] || die "Senha não encontrada: ${RESTIC_PASSWORD_FILE}"

  export RESTIC_REPOSITORY
  export RESTIC_PASSWORD_FILE
  BACKUP_MUSIC="${BACKUP_MUSIC:-true}"
  BACKUP_PHOTOS="${BACKUP_PHOTOS:-true}"
  BACKUP_DOWNLOADS="${BACKUP_DOWNLOADS:-false}"
  KEEP_DAILY="${KEEP_DAILY:-7}"
  KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
  KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
  KEEP_YEARLY="${KEEP_YEARLY:-2}"
  BACKUP_LOG_DIR="${BACKUP_LOG_DIR:-${STATE_DIR}/logs}"
}

resolve_paths() {
  if load_state; then
    MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
    PHOTOS_ROOT="${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}"
  else
    MOUNT_POINT="${MOUNT_POINT:-/media/music}"
    MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
    PHOTOS_ROOT="${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}"
  fi
}

ensure_mount_ready() {
  if [[ ! -d "${MOUNT_POINT}" ]]; then
    die "Ponto de montagem inexistente: ${MOUNT_POINT}"
  fi
  if ! mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    die "HD não montado em ${MOUNT_POINT}. Rode: sudo ./mount.sh"
  fi
}

run_restic() {
  local log_file="${BACKUP_LOG_DIR}/restic-$(date +%Y%m%d).log"
  mkdir -p "${BACKUP_LOG_DIR}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    restic "$@" --dry-run 2>&1 | tee -a "${log_file}"
  else
    restic "$@" 2>&1 | tee -a "${log_file}"
  fi
}

do_backup() {
  local paths=()
  local excludes=(
    --exclude "Downloads/**"
    --exclude "**/Incomplete/**"
    --exclude "**/*.!qB"
    --exclude "**/*.part"
    --exclude "**/*.tmp"
    --exclude "**/.Trash*"
    --exclude "**/lost+found"
  )

  if [[ "${BACKUP_DOWNLOADS}" == "true" ]]; then
    excludes=()
  fi

  if [[ "${BACKUP_MUSIC}" == "true" && -d "${MUSIC_ROOT}" ]]; then
    paths+=("${MUSIC_ROOT}")
  fi
  if [[ "${BACKUP_PHOTOS}" == "true" && -d "${PHOTOS_ROOT}" ]]; then
    paths+=("${PHOTOS_ROOT}")
  fi

  if [[ ${#paths[@]} -eq 0 ]]; then
    die "Nenhuma origem para backup (MUSIC/PHOTOS)"
  fi

  log_step "restic backup → ${RESTIC_REPOSITORY}"
  echo -e "  Origens: ${paths[*]}"

  local args=(backup --one-file-system --tag music-server)
  if [[ "${BACKUP_DOWNLOADS}" != "true" ]]; then
    args+=("${excludes[@]}")
  fi
  args+=("${paths[@]}")

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[dry-run] restic ${args[*]}"
    restic backup --dry-run --one-file-system --tag music-server "${excludes[@]}" "${paths[@]}" || true
  else
    restic "${args[@]}"
  fi
  log_ok "Snapshot criado"
}

do_prune() {
  log_step "restic forget/prune (retenção)"
  local args=(
    forget
    --prune
    --keep-daily "${KEEP_DAILY}"
    --keep-weekly "${KEEP_WEEKLY}"
    --keep-monthly "${KEEP_MONTHLY}"
    --keep-yearly "${KEEP_YEARLY}"
    --tag music-server
  )
  if [[ "${DRY_RUN}" == "true" ]]; then
    restic forget --dry-run \
      --keep-daily "${KEEP_DAILY}" \
      --keep-weekly "${KEEP_WEEKLY}" \
      --keep-monthly "${KEEP_MONTHLY}" \
      --keep-yearly "${KEEP_YEARLY}" \
      --tag music-server || true
  else
    restic "${args[@]}"
  fi
  log_ok "Retenção aplicada"
}

main() {
  parse_args "$@"
  require_root

  if ! command -v restic >/dev/null 2>&1; then
    die "restic não instalado. Execute: sudo ./setup-security.sh"
  fi

  load_restic_conf
  resolve_paths

  if [[ "${PRUNE_ONLY}" != "true" ]]; then
    ensure_mount_ready
    do_backup
  fi
  do_prune

  if [[ "${DRY_RUN}" != "true" ]]; then
    restic check --read-data-subset=5% 2>/dev/null || restic check || log_warn "restic check avisou — veja o log"
  fi

  log_ok "restic concluído"
  echo -e "${C_DIM}Listar: sudo RESTIC_REPOSITORY=... RESTIC_PASSWORD_FILE=... restic snapshots${C_RESET}"
  echo -e "${C_DIM}Ou:     source ${RESTIC_CONF} && export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE && restic snapshots${C_RESET}"
}

main "$@"
