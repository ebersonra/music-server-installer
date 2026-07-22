#!/usr/bin/env bash
# restore-restic.sh — Restaura snapshots restic (local ou baixados da nuvem)
# Uso:
#   sudo ./restore-restic.sh --list
#   sudo ./restore-restic.sh --target /tmp/restore-test
#   sudo ./restore-restic.sh --target /tmp/fotos --photos-only
#   sudo ./restore-restic.sh --target /tmp/restore --from-cloud
#   sudo ./restore-restic.sh --target /tmp/x --snapshot 97b32555
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"

RESTIC_CONF="${STATE_DIR}/restic-backup.conf"
CLOUD_CONF="${STATE_DIR}/cloud-backup.conf"

LIST_ONLY=false
DRY_RUN=false
FROM_CLOUD=false
MUSIC_ONLY=false
PHOTOS_ONLY=false
SNAPSHOT_ID="latest"
TARGET=""
INCLUDE_PATH=""
CLOUD_REPO_DIR=""
VERIFY=false

usage() {
  cat <<EOF
Uso: sudo ./restore-restic.sh [opções]

Restaura músicas/fotos a partir de snapshots restic criptografados.

Opções:
  --list                 Só lista snapshots (não restaura)
  --target DIR           Destino do restore (obrigatório, exceto com --list)
  --snapshot ID          ID do snapshot ou "latest" (padrão: latest)
  --music-only           Só /media/music/Musicas (ou MUSIC_ROOT)
  --photos-only          Só /media/music/Fotos (ou PHOTOS_ROOT)
  --include PATH         Caminho absoluto dentro do snapshot (ex.: /media/music/Fotos)
  --from-cloud           Baixa o repo de remote:.../restic-repo antes (rclone)
  --cloud-repo-dir DIR   Onde gravar o repo baixado (padrão: STATE_DIR/restic-from-cloud)
  --verify               Após restore, compara alguns arquivos (restic check no repo)
  --dry-run              Mostra o que seria feito (restic restore --dry-run)
  -h, --help             Esta ajuda

Exemplos:
  sudo ./restore-restic.sh --list
  sudo ./restore-restic.sh --target /tmp/restore-test
  sudo ./restore-restic.sh --target /tmp/fotos --photos-only
  sudo ./restore-restic.sh --target /tmp/restore --from-cloud --dry-run

Senha: ${STATE_DIR}/restic.password  (guarde fora do PC)
Guia:  docs/security.md
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list) LIST_ONLY=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --from-cloud) FROM_CLOUD=true; shift ;;
      --verify) VERIFY=true; shift ;;
      --music-only) MUSIC_ONLY=true; shift ;;
      --photos-only) PHOTOS_ONLY=true; shift ;;
      --target)
        [[ $# -ge 2 ]] || die "--target requer um diretório"
        TARGET="$2"
        shift 2
        ;;
      --snapshot)
        [[ $# -ge 2 ]] || die "--snapshot requer um ID"
        SNAPSHOT_ID="$2"
        shift 2
        ;;
      --include)
        [[ $# -ge 2 ]] || die "--include requer um caminho"
        INCLUDE_PATH="$2"
        shift 2
        ;;
      --cloud-repo-dir)
        [[ $# -ge 2 ]] || die "--cloud-repo-dir requer um caminho"
        CLOUD_REPO_DIR="$2"
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

load_restic_conf() {
  if [[ ! -f "${RESTIC_CONF}" ]]; then
    die "Config não encontrada: ${RESTIC_CONF}
Execute: sudo ./setup-security.sh --only-restic"
  fi
  # shellcheck source=/dev/null
  source "${RESTIC_CONF}"

  [[ -n "${RESTIC_REPOSITORY:-}" ]] || die "RESTIC_REPOSITORY vazio em ${RESTIC_CONF}"
  [[ -f "${RESTIC_PASSWORD_FILE:-}" ]] || die "Senha não encontrada: ${RESTIC_PASSWORD_FILE}
Sem ela não há restore. Se perdeu a senha, os snapshots são irrecuperáveis."

  export RESTIC_REPOSITORY
  export RESTIC_PASSWORD_FILE
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

  if [[ "${MUSIC_ONLY}" == "true" && "${PHOTOS_ONLY}" == "true" ]]; then
    die "Use só um de --music-only / --photos-only"
  fi
  if [[ "${MUSIC_ONLY}" == "true" ]]; then
    INCLUDE_PATH="${MUSIC_ROOT}"
  fi
  if [[ "${PHOTOS_ONLY}" == "true" ]]; then
    INCLUDE_PATH="${PHOTOS_ROOT}"
  fi
}

rclone_backup_user() {
  local backup_user="${BACKUP_USER:-}"
  if [[ -z "${backup_user}" ]]; then
    backup_user="${TARGET_USER:-${SUDO_USER:-}}"
  fi
  if [[ -z "${backup_user}" ]] || ! id "${backup_user}" &>/dev/null; then
    die "BACKUP_USER inválido para rclone. Configure: sudo ./setup-cloud-backup.sh"
  fi
  printf '%s' "${backup_user}"
}

rclone_conf_path() {
  local backup_user conf_home
  backup_user="$(rclone_backup_user)"
  conf_home="$(getent passwd "${backup_user}" | cut -d: -f6)"
  local rclone_conf="${conf_home}/.config/rclone/rclone.conf"
  if [[ ! -f "${rclone_conf}" ]]; then
    die "rclone.conf não encontrado em ${rclone_conf}"
  fi
  printf '%s' "${rclone_conf}"
}

# root + conf do usuário (repo remoto → disco local)
rclone_as_root_with_user_conf() {
  local rclone_conf
  rclone_conf="$(rclone_conf_path)"
  [[ "${EUID}" -eq 0 ]] || die "Download do repo na nuvem precisa de root"
  env RCLONE_CONFIG="${rclone_conf}" rclone "$@"
}

download_repo_from_cloud() {
  if [[ ! -f "${CLOUD_CONF}" ]]; then
    die "Config cloud não encontrada: ${CLOUD_CONF}
Execute: sudo ./setup-cloud-backup.sh"
  fi
  # shellcheck source=/dev/null
  source "${CLOUD_CONF}"

  local remote="${RCLONE_REMOTE:-gdrive}"
  local path="${RCLONE_PATH:-music-server-backup}"
  local sub="${RESTIC_CLOUD_SUBDIR:-restic-repo}"
  local src="${remote}:${path}/${sub}"

  CLOUD_REPO_DIR="${CLOUD_REPO_DIR:-${STATE_DIR}/restic-from-cloud}"

  if ! command -v rclone >/dev/null 2>&1; then
    die "rclone não instalado. Execute: sudo ./setup-cloud-backup.sh"
  fi

  log_step "Baixando repositório restic da nuvem"
  echo -e "  Origem:  ${src}"
  echo -e "  Destino: ${CLOUD_REPO_DIR}"

  mkdir -p "${CLOUD_REPO_DIR}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[dry-run] rclone sync ${src} → ${CLOUD_REPO_DIR}"
    rclone_as_root_with_user_conf sync "${src}" "${CLOUD_REPO_DIR}" --dry-run --stats 1m --stats-one-line \
      || log_warn "rclone dry-run avisou"
  else
    rclone_as_root_with_user_conf sync "${src}" "${CLOUD_REPO_DIR}" \
      --fast-list --checkers 8 --transfers 4 --tpslimit 8 --stats 1m --stats-one-line \
      || die "Falha ao baixar ${src}"
    log_ok "Repo baixado em ${CLOUD_REPO_DIR}"
  fi

  RESTIC_REPOSITORY="${CLOUD_REPO_DIR}"
  export RESTIC_REPOSITORY
}

list_snapshots() {
  log_step "Snapshots em ${RESTIC_REPOSITORY}"
  restic snapshots --tag music-server 2>/dev/null || restic snapshots
  echo
  echo -e "${C_DIM}Detalhe: restic ls ${SNAPSHOT_ID} | less${C_RESET}"
  echo -e "${C_DIM}Buscar:  restic find 'nome-arquivo'${C_RESET}"
}

do_restore() {
  [[ -n "${TARGET}" ]] || die "--target é obrigatório para restaurar (ou use --list)"

  if [[ "${TARGET}" == "/" ]]; then
    die "Recusar restore com --target / (perigoso)"
  fi

  mkdir -p "${TARGET}"

  local snap_arg="${SNAPSHOT_ID}"
  # Sintaxe snapshot:subpasta → dest fica mais limpo (sem /media/music/... aninhado)
  if [[ -n "${INCLUDE_PATH}" ]]; then
    snap_arg="${SNAPSHOT_ID}:${INCLUDE_PATH}"
  fi

  echo
  echo -e "${C_BOLD}Restore restic${C_RESET}"
  echo -e "  Repositório: ${RESTIC_REPOSITORY}"
  echo -e "  Snapshot:    ${snap_arg}"
  echo -e "  Destino:     ${TARGET}"
  if [[ -n "${INCLUDE_PATH}" ]]; then
    echo -e "  Include:     ${INCLUDE_PATH}"
  fi
  echo

  if [[ "${DRY_RUN}" != "true" ]]; then
    if ! confirm "Confirmar restore para ${TARGET}?"; then
      die "Cancelado"
    fi
  fi

  local args=(restore "${snap_arg}" --target "${TARGET}")
  if [[ "${DRY_RUN}" == "true" ]]; then
    args+=(--dry-run)
    log_info "[dry-run] restic ${args[*]}"
  else
    log_step "Restaurando…"
  fi

  restic "${args[@]}"
  log_ok "Restore concluído → ${TARGET}"

  if [[ -n "${INCLUDE_PATH}" ]]; then
    echo -e "${C_DIM}Arquivos em: ${TARGET}/ (conteúdo de ${INCLUDE_PATH})${C_RESET}"
  else
    echo -e "${C_DIM}Paths absolutos recriados sob o target, ex.:${C_RESET}"
    echo -e "${C_DIM}  ${TARGET}${MUSIC_ROOT}${C_RESET}"
    echo -e "${C_DIM}  ${TARGET}${PHOTOS_ROOT}${C_RESET}"
  fi
}

maybe_verify() {
  if [[ "${VERIFY}" != "true" ]]; then
    return 0
  fi
  log_step "Verificando integridade do repositório (amostra)"
  restic check --read-data-subset=5% 2>/dev/null || restic check || log_warn "restic check avisou"
}

main() {
  parse_args "$@"
  require_root

  if ! command -v restic >/dev/null 2>&1; then
    die "restic não instalado. Execute: sudo ./setup-security.sh --only-restic"
  fi

  load_restic_conf
  resolve_paths

  if [[ "${FROM_CLOUD}" == "true" ]]; then
    download_repo_from_cloud
  fi

  # Canonicalizar path local
  if [[ "${RESTIC_REPOSITORY}" == /* ]] && command -v realpath >/dev/null 2>&1; then
    RESTIC_REPOSITORY="$(realpath -m "${RESTIC_REPOSITORY}")"
    export RESTIC_REPOSITORY
  fi

  if [[ "${RESTIC_REPOSITORY}" == /* && ! -d "${RESTIC_REPOSITORY}" ]]; then
    die "Repositório inexistente: ${RESTIC_REPOSITORY}
Crie snapshots: sudo ./backup-restic.sh
Ou restaure da nuvem: sudo ./restore-restic.sh --from-cloud --list"
  fi

  if [[ "${LIST_ONLY}" == "true" ]]; then
    list_snapshots
    exit 0
  fi

  do_restore
  maybe_verify

  echo
  log_ok "Pronto"
  echo -e "${C_DIM}Listar de novo: sudo ./restore-restic.sh --list${C_RESET}"
  echo -e "${C_DIM}Guia:           docs/security.md${C_RESET}"
}

main "$@"
