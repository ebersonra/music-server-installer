#!/usr/bin/env bash
# backup-cloud.sh — Envia backup compactado (zip) ou repositório restic para a nuvem
# Uso:
#   sudo ./backup-cloud.sh                 # conforme BACKUP_PAYLOAD na config
#   sudo ./backup-cloud.sh --dry-run
#   sudo ./backup-cloud.sh --payload restic
#   sudo ./backup-cloud.sh --payload zip
#   sudo ./backup-cloud.sh --music-only
#   sudo ./backup-cloud.sh --photos-only
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"

CLOUD_CONF="${STATE_DIR}/cloud-backup.conf"
RESTIC_CONF="${STATE_DIR}/restic-backup.conf"
DRY_RUN=false
MUSIC_ONLY=false
PHOTOS_ONLY=false
PAYLOAD_OVERRIDE=""

usage() {
  cat <<EOF
Uso: sudo ./backup-cloud.sh [opções]

Envia cópia de segurança para a nuvem (rclone). Em vez de espelhar arquivos
soltos (já no HD / Google Fotos), sobe:

  restic  — repositório de snapshots criptografados (recomendado)
  zip     — arquivos *.zip datados de músicas/fotos

Opções:
  --dry-run              Simula sem enviar
  --payload restic|zip   Sobrescreve BACKUP_PAYLOAD da config
  --music-only           Só biblioteca de músicas (modo zip)
  --photos-only          Só pasta de fotos (modo zip)
  -h, --help             Esta ajuda

Configure antes com: sudo ./setup-cloud-backup.sh
Snapshots locais:     sudo ./backup-restic.sh  (modo restic)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --payload)
        [[ $# -ge 2 ]] || die "--payload requer restic ou zip"
        PAYLOAD_OVERRIDE="$2"
        shift 2
        ;;
      --music-only) MUSIC_ONLY=true; shift ;;
      --photos-only) PHOTOS_ONLY=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

load_cloud_conf() {
  if [[ ! -f "${CLOUD_CONF}" ]]; then
    die "Config não encontrada: ${CLOUD_CONF}
Execute: sudo ./setup-cloud-backup.sh"
  fi
  # shellcheck source=/dev/null
  source "${CLOUD_CONF}"

  RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"
  RCLONE_PATH="${RCLONE_PATH:-music-server-backup}"
  RCLONE_MODE="${RCLONE_MODE:-copy}"
  BACKUP_PAYLOAD="${PAYLOAD_OVERRIDE:-${BACKUP_PAYLOAD:-restic}}"
  BACKUP_MUSIC="${BACKUP_MUSIC:-true}"
  BACKUP_PHOTOS="${BACKUP_PHOTOS:-true}"
  BACKUP_DOWNLOADS="${BACKUP_DOWNLOADS:-false}"
  BACKUP_LOG_DIR="${BACKUP_LOG_DIR:-${STATE_DIR}/logs}"
  RCLONE_EXTRA_OPTS="${RCLONE_EXTRA_OPTS:---fast-list --checkers 8 --transfers 4 --tpslimit 8}"

  # Modo restic
  RUN_RESTIC_FIRST="${RUN_RESTIC_FIRST:-true}"
  RESTIC_CLOUD_SUBDIR="${RESTIC_CLOUD_SUBDIR:-restic-repo}"

  # Modo zip
  ZIP_STAGING_DIR="${ZIP_STAGING_DIR:-}"
  ZIP_KEEP_LOCAL="${ZIP_KEEP_LOCAL:-1}"
  ZIP_KEEP_REMOTE="${ZIP_KEEP_REMOTE:-3}"
  ZIP_COMPRESSION="${ZIP_COMPRESSION:-0}"
}

resolve_paths() {
  if load_state; then
    MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
    PHOTOS_ROOT="${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}"
  else
    log_warn "Estado do instalador não encontrado — usando defaults"
    MOUNT_POINT="${MOUNT_POINT:-/media/music}"
    MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
    PHOTOS_ROOT="${PHOTOS_ROOT:-${MOUNT_POINT}/Fotos}"
  fi

  # Preferir staging no HD externo (zips grandes não enchem o root)
  if [[ -z "${ZIP_STAGING_DIR}" ]]; then
    if [[ -d "${MOUNT_POINT}" ]]; then
      ZIP_STAGING_DIR="${MOUNT_POINT}/.music-server-zip-staging"
    else
      ZIP_STAGING_DIR="${STATE_DIR}/zip-staging"
    fi
  fi

  if [[ "${MUSIC_ONLY}" == "true" ]]; then
    BACKUP_MUSIC=true
    BACKUP_PHOTOS=false
  fi
  if [[ "${PHOTOS_ONLY}" == "true" ]]; then
    BACKUP_MUSIC=false
    BACKUP_PHOTOS=true
  fi
}

ensure_mount_ready() {
  if [[ ! -d "${MOUNT_POINT}" ]]; then
    die "Ponto de montagem inexistente: ${MOUNT_POINT}"
  fi
  if ! mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    log_warn "${MOUNT_POINT} não parece montado — tente: sudo ./mount.sh"
    die "HD não montado em ${MOUNT_POINT}. Remonte e rode o backup de novo."
  fi
}

rclone_backup_user() {
  local backup_user="${BACKUP_USER:-}"
  if [[ -z "${backup_user}" ]]; then
    backup_user="${TARGET_USER:-${SUDO_USER:-}}"
  fi
  if [[ -z "${backup_user}" ]] || ! id "${backup_user}" &>/dev/null; then
    die "BACKUP_USER inválido. Defina em ${CLOUD_CONF}"
  fi
  printf '%s' "${backup_user}"
}

ensure_backup_log_dir() {
  local backup_user
  backup_user="$(rclone_backup_user)"
  mkdir -p "${BACKUP_LOG_DIR}"
  chown "${backup_user}:${backup_user}" "${BACKUP_LOG_DIR}"
  chmod 750 "${BACKUP_LOG_DIR}"
}

rclone_as_user() {
  local backup_user
  backup_user="$(rclone_backup_user)"

  local conf_home
  conf_home="$(getent passwd "${backup_user}" | cut -d: -f6)"
  local rclone_conf="${conf_home}/.config/rclone/rclone.conf"
  if [[ ! -f "${rclone_conf}" ]]; then
    die "rclone.conf não encontrado em ${rclone_conf}
Como ${backup_user}, rode: rclone config"
  fi

  if [[ "${EUID}" -eq 0 ]]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "${backup_user}" -- env RCLONE_CONFIG="${rclone_conf}" rclone "$@"
    else
      sudo -u "${backup_user}" -- env RCLONE_CONFIG="${rclone_conf}" rclone "$@"
    fi
  else
    RCLONE_CONFIG="${rclone_conf}" rclone "$@"
  fi
}

run_rclone_transfer() {
  local label="$1"
  local src="$2"
  local dest="$3"
  shift 3
  local excludes=("$@")

  local log_file="${BACKUP_LOG_DIR}/backup-${label}-$(date +%Y%m%d).log"
  local backup_user
  backup_user="$(rclone_backup_user)"

  ensure_backup_log_dir
  touch "${log_file}"
  chown "${backup_user}:${backup_user}" "${log_file}"

  local cmd=(copy)
  if [[ "${RCLONE_MODE}" == "sync" ]]; then
    cmd=(sync)
  fi

  local args=(
    "${cmd[@]}"
    "${src}"
    "${dest}"
    --log-file "${log_file}"
    --log-level INFO
    --stats 1m
    --stats-one-line
  )

  # shellcheck disable=SC2206
  local extra=( ${RCLONE_EXTRA_OPTS} )
  args+=("${extra[@]}")

  local ex
  for ex in "${excludes[@]}"; do
    args+=(--exclude "${ex}")
  done

  if [[ "${DRY_RUN}" == "true" ]]; then
    args+=(--dry-run)
    log_info "[dry-run] ${label}: ${src} → ${dest}"
  else
    log_step "Upload ${label}: ${src} → ${dest}"
  fi

  if rclone_as_user "${args[@]}"; then
    log_ok "${label} concluído (log: ${log_file})"
  else
    log_error "${label} falhou — veja ${log_file}"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Modo restic: sobe o repositório de snapshots (criptografado + deduplicado)
# -----------------------------------------------------------------------------
load_restic_repo() {
  if [[ ! -f "${RESTIC_CONF}" ]]; then
    die "Config restic não encontrada: ${RESTIC_CONF}
Execute: sudo ./setup-security.sh --only-restic
Ou use:  sudo ./backup-cloud.sh --payload zip"
  fi
  # shellcheck source=/dev/null
  source "${RESTIC_CONF}"
  [[ -n "${RESTIC_REPOSITORY:-}" ]] || die "RESTIC_REPOSITORY vazio em ${RESTIC_CONF}"
}

maybe_run_restic_first() {
  if [[ "${RUN_RESTIC_FIRST}" != "true" ]]; then
    return 0
  fi
  local restic_script="${INSTALLER_ROOT}/backup-restic.sh"
  [[ -x "${restic_script}" ]] || die "Script não encontrado: ${restic_script}"

  log_step "Atualizando snapshots locais (backup-restic.sh)"
  if [[ "${DRY_RUN}" == "true" ]]; then
    "${restic_script}" --dry-run || log_warn "restic dry-run avisou"
  else
    "${restic_script}"
  fi
}

upload_restic_repo() {
  load_restic_repo

  # Já aponta para a nuvem via backend rclone do restic — nada a espelhar
  if [[ "${RESTIC_REPOSITORY}" == rclone:* ]]; then
    log_ok "RESTIC_REPOSITORY já usa rclone (${RESTIC_REPOSITORY})"
    log_info "Os snapshots já vão direto para a nuvem. Rodando restic se necessário…"
    maybe_run_restic_first
    log_ok "Modo restic (remote direto) concluído — não há cópia extra via rclone"
    return 0
  fi

  # Repositório local (ou caminho absoluto) → sync para a nuvem
  if [[ "${RESTIC_REPOSITORY}" != /* ]]; then
    die "RESTIC_REPOSITORY não é caminho local nem rclone::
  ${RESTIC_REPOSITORY}
Para modo cloud, use path local (ex.: /mnt/backup/restic-repo) ou rclone:gdrive:..."
  fi

  if [[ ! -d "${RESTIC_REPOSITORY}" ]]; then
    die "Repositório restic inexistente: ${RESTIC_REPOSITORY}
Crie o 1º snapshot: sudo ./backup-restic.sh"
  fi

  maybe_run_restic_first

  local dest="${RCLONE_REMOTE}:${RCLONE_PATH}/${RESTIC_CLOUD_SUBDIR}"
  # sync mantém o repo remoto alinhado (prune local remove packs órfãos)
  local saved_mode="${RCLONE_MODE}"
  RCLONE_MODE="sync"
  run_rclone_transfer "restic-repo" "${RESTIC_REPOSITORY}" "${dest}" \
    "**/.lock" || { RCLONE_MODE="${saved_mode}"; return 1; }
  RCLONE_MODE="${saved_mode}"
}

# -----------------------------------------------------------------------------
# Modo zip: compacta origens e sobe *.zip datados
# -----------------------------------------------------------------------------
ensure_zip_tools() {
  if ! command -v zip >/dev/null 2>&1; then
    log_step "Instalando zip"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq zip || die "Não foi possível instalar zip"
  fi
}

build_zip_excludes() {
  local -n _out=$1
  _out=()
  if [[ "${BACKUP_DOWNLOADS}" != "true" ]]; then
    _out+=(
      -x "*/Downloads/*"
      -x "*/Incomplete/*"
      -x "*.!qB"
      -x "*.part"
      -x "*.tmp"
    )
  fi
  _out+=(-x "*/.Trash*" -x "*/lost+found/*" -x "*/.*" -x "*~")
}

create_and_upload_zip() {
  local label="$1"
  local src="$2"
  local stamp
  stamp="$(date +%Y%m%d)"
  local zip_name="${label}-${stamp}.zip"
  local zip_path="${ZIP_STAGING_DIR}/${zip_name}"
  local dest="${RCLONE_REMOTE}:${RCLONE_PATH}/zips"

  if [[ ! -d "${src}" ]]; then
    log_warn "Origem inexistente, pulando: ${src}"
    return 0
  fi

  mkdir -p "${ZIP_STAGING_DIR}"

  local excludes=()
  build_zip_excludes excludes

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[dry-run] zip -r -${ZIP_COMPRESSION} ${zip_path} ← ${src}"
    log_info "[dry-run] upload → ${dest}/${zip_name}"
    return 0
  fi

  log_step "Compactando ${label} → ${zip_path}"
  log_info "Nível zip=${ZIP_COMPRESSION} (0=store: ideal p/ mp3/jpg já comprimidos)"

  # Remove zip do mesmo dia se existir (reexecução)
  rm -f "${zip_path}"

  # zip a partir do diretório pai para caminhos relativos limpos
  local parent base
  parent="$(dirname "${src}")"
  base="$(basename "${src}")"
  (
    cd "${parent}"
    # shellcheck disable=SC2086
    zip -r -"${ZIP_COMPRESSION}" "${zip_path}" "${base}" "${excludes[@]}"
  )

  local size
  size="$(du -sh "${zip_path}" | awk '{print $1}')"
  log_ok "Zip criado (${size}): ${zip_path}"

  run_rclone_transfer "zip-${label}" "${zip_path}" "${dest}" || return 1

  prune_local_zips "${label}"
  prune_remote_zips "${label}"
}

prune_local_zips() {
  local label="$1"
  local keep="${ZIP_KEEP_LOCAL}"
  [[ "${keep}" =~ ^[0-9]+$ ]] || return 0
  [[ -d "${ZIP_STAGING_DIR}" ]] || return 0

  mapfile -t files < <(ls -1t "${ZIP_STAGING_DIR}/${label}"-*.zip 2>/dev/null || true)
  local i=0
  for f in "${files[@]}"; do
    i=$((i + 1))
    if (( i > keep )); then
      log_info "Removendo zip local antigo: ${f}"
      rm -f "${f}"
    fi
  done
}

prune_remote_zips() {
  local label="$1"
  local keep="${ZIP_KEEP_REMOTE}"
  [[ "${keep}" =~ ^[0-9]+$ ]] || return 0
  (( keep >= 1 )) || return 0

  local dest="${RCLONE_REMOTE}:${RCLONE_PATH}/zips"
  local listing
  if ! listing="$(rclone_as_user lsf "${dest}" --include "${label}-*.zip" 2>/dev/null | sort -r)"; then
    return 0
  fi

  local i=0
  local name
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    i=$((i + 1))
    if (( i > keep )); then
      if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[dry-run] apagar remoto: ${dest}/${name}"
      else
        log_info "Removendo zip remoto antigo: ${name}"
        rclone_as_user deletefile "${dest}/${name}" || log_warn "Falha ao apagar ${name}"
      fi
    fi
  done <<< "${listing}"
}

run_zip_payload() {
  ensure_zip_tools
  ensure_mount_ready

  log_warn "Áudio/fotos já são comprimidos — zip economiza pouco vs. restic (dedupe + histórico)"
  echo -e "  Staging: ${ZIP_STAGING_DIR}"
  echo -e "  Manter local:  ${ZIP_KEEP_LOCAL} | remoto: ${ZIP_KEEP_REMOTE}"
  echo

  local failed=0
  if [[ "${BACKUP_MUSIC}" == "true" ]]; then
    create_and_upload_zip "musicas" "${MUSIC_ROOT}" || failed=1
  fi
  if [[ "${BACKUP_PHOTOS}" == "true" ]]; then
    create_and_upload_zip "fotos" "${PHOTOS_ROOT}" || failed=1
  fi
  return "${failed}"
}

# -----------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_root
  load_cloud_conf
  resolve_paths

  if ! command -v rclone >/dev/null 2>&1; then
    die "rclone não instalado. Execute: sudo ./setup-cloud-backup.sh"
  fi

  case "${BACKUP_PAYLOAD}" in
    restic|zip) ;;
    files)
      die "BACKUP_PAYLOAD=files foi removido (copia bruta desperdiça espaço).
Use restic (recomendado) ou zip. Edite: ${CLOUD_CONF}"
      ;;
    *)
      die "BACKUP_PAYLOAD inválido: ${BACKUP_PAYLOAD} (use restic ou zip)"
      ;;
  esac

  if [[ "${RCLONE_MODE}" != "copy" && "${RCLONE_MODE}" != "sync" ]]; then
    die "RCLONE_MODE inválido: ${RCLONE_MODE} (use copy ou sync)"
  fi

  echo
  echo -e "${C_BOLD}Backup nuvem${C_RESET}"
  echo -e "  Remote:   ${RCLONE_REMOTE}:${RCLONE_PATH}"
  echo -e "  Payload:  ${BACKUP_PAYLOAD}"
  echo -e "  Modo:     ${RCLONE_MODE}"
  if [[ "${BACKUP_PAYLOAD}" == "zip" ]]; then
    echo -e "  Músicas:  ${BACKUP_MUSIC} (${MUSIC_ROOT})"
    echo -e "  Fotos:    ${BACKUP_PHOTOS} (${PHOTOS_ROOT})"
  fi
  echo

  if ! rclone_as_user lsd "${RCLONE_REMOTE}:" >/dev/null 2>&1; then
    die "Não foi possível listar ${RCLONE_REMOTE}: — rode rclone config como ${BACKUP_USER:-$TARGET_USER}"
  fi

  local failed=0

  case "${BACKUP_PAYLOAD}" in
    restic)
      upload_restic_repo || failed=1
      ;;
    zip)
      run_zip_payload || failed=1
      ;;
  esac

  if [[ "${failed}" -ne 0 ]]; then
    die "Backup terminou com erros"
  fi

  log_ok "Backup concluído"
}

main "$@"
