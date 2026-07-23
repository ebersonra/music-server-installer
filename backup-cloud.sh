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
IGNORE_WINDOW=false

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
  --ignore-window        Ignora janela horária (BACKUP_WINDOW_*)
  -h, --help             Esta ajuda

Configure antes com: sudo ./setup-cloud-backup.sh
Snapshots locais:     sudo ./backup-restic.sh  (modo restic)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --ignore-window) IGNORE_WINDOW=true; shift ;;
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
  RCLONE_EXTRA_OPTS="${RCLONE_EXTRA_OPTS:---fast-list --retries 5 --low-level-retries 10}"

  # Rate limit (Google Drive / APIs sensíveis) — delay entre requests + paralelismo baixo
  RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-2}"
  RCLONE_CHECKERS="${RCLONE_CHECKERS:-4}"
  RCLONE_TPSLIMIT="${RCLONE_TPSLIMIT:-4}"
  RCLONE_TPSLIMIT_BURST="${RCLONE_TPSLIMIT_BURST:-1}"
  RCLONE_DRIVE_PACER_MIN_SLEEP="${RCLONE_DRIVE_PACER_MIN_SLEEP:-200ms}"
  RCLONE_RETRIES_SLEEP="${RCLONE_RETRIES_SLEEP:-30s}"

  # Modo restic
  RUN_RESTIC_FIRST="${RUN_RESTIC_FIRST:-true}"
  RESTIC_CLOUD_SUBDIR="${RESTIC_CLOUD_SUBDIR:-restic-repo}"

  # Modo zip
  ZIP_STAGING_DIR="${ZIP_STAGING_DIR:-}"
  ZIP_KEEP_LOCAL="${ZIP_KEEP_LOCAL:-1}"
  ZIP_KEEP_REMOTE="${ZIP_KEEP_REMOTE:-3}"
  ZIP_COMPRESSION="${ZIP_COMPRESSION:-0}"

  # Janela horária (ex.: 17:00–06:00); rclone retoma na próxima noite
  BACKUP_WINDOW_ENABLED="${BACKUP_WINDOW_ENABLED:-false}"
  BACKUP_WINDOW_START="${BACKUP_WINDOW_START:-17:00}"
  BACKUP_WINDOW_END="${BACKUP_WINDOW_END:-06:00}"
  # Duração máxima calculada até o fim da janela; sobrescreva se quiser fixo (ex.: 13h)
  BACKUP_MAX_DURATION="${BACKUP_MAX_DURATION:-}"
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

# Como executar o rclone: user (OAuth como BACKUP_USER) | root (lê repo restic 700)
RCLONE_RUN_MODE="${RCLONE_RUN_MODE:-user}"
RCLONE_MAX_DURATION_ARGS=()

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

rclone_conf_path() {
  local backup_user conf_home
  backup_user="$(rclone_backup_user)"
  conf_home="$(getent passwd "${backup_user}" | cut -d: -f6)"
  local rclone_conf="${conf_home}/.config/rclone/rclone.conf"
  if [[ ! -f "${rclone_conf}" ]]; then
    die "rclone.conf não encontrado em ${rclone_conf}
Como ${backup_user}, rode: rclone config"
  fi
  printf '%s' "${rclone_conf}"
}

ensure_backup_log_dir() {
  local backup_user
  backup_user="$(rclone_backup_user)"
  mkdir -p "${BACKUP_LOG_DIR}"
  chown "${backup_user}:${backup_user}" "${BACKUP_LOG_DIR}"
  chmod 750 "${BACKUP_LOG_DIR}"
}

# rclone com o conf do BACKUP_USER, mas sem dropar root (lê /media/backup-restic 700)
rclone_as_root_with_user_conf() {
  local rclone_conf
  rclone_conf="$(rclone_conf_path)"
  if [[ "${EUID}" -ne 0 ]]; then
    die "Sync do repositório restic precisa de root (pastas do repo são 700 root)"
  fi
  env RCLONE_CONFIG="${rclone_conf}" rclone "$@"
}

# rclone como BACKUP_USER (OAuth / tokens no home do usuário)
rclone_as_user() {
  local backup_user rclone_conf
  backup_user="$(rclone_backup_user)"
  rclone_conf="$(rclone_conf_path)"

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

rclone_exec() {
  case "${RCLONE_RUN_MODE}" in
    root) rclone_as_root_with_user_conf "$@" ;;
    user) rclone_as_user "$@" ;;
    *) die "RCLONE_RUN_MODE inválido: ${RCLONE_RUN_MODE} (use user ou root)" ;;
  esac
}

# HH:MM → minutos desde 00:00
_hhmm_to_minutes() {
  local t="$1"
  local h m
  if ! [[ "${t}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    die "Horário inválido (use HH:MM): ${t}"
  fi
  h="${BASH_REMATCH[1]}"
  m="${BASH_REMATCH[2]}"
  h=$((10#${h}))
  m=$((10#${m}))
  if (( h > 23 || m > 59 )); then
    die "Horário fora do intervalo: ${t}"
  fi
  echo $((h * 60 + m))
}

# true se agora está dentro de [START, END); janela que cruza meia-noite (ex. 22:00–06:00) ok
in_backup_window() {
  local now start_m end_m
  now="$(date +%H:%M)"
  start_m="$(_hhmm_to_minutes "${BACKUP_WINDOW_START}")"
  end_m="$(_hhmm_to_minutes "${BACKUP_WINDOW_END}")"
  local now_m
  now_m="$(_hhmm_to_minutes "${now}")"

  if (( start_m == end_m )); then
    return 0  # janela de 24h
  fi
  if (( start_m < end_m )); then
    # ex.: 00:00–06:00
    (( now_m >= start_m && now_m < end_m ))
  else
    # ex.: 22:00–06:00
    (( now_m >= start_m || now_m < end_m ))
  fi
}

# segundos até BACKUP_WINDOW_END (mínimo 60s)
seconds_until_window_end() {
  local now_m end_m start_m
  now_m="$(_hhmm_to_minutes "$(date +%H:%M)")"
  end_m="$(_hhmm_to_minutes "${BACKUP_WINDOW_END}")"
  start_m="$(_hhmm_to_minutes "${BACKUP_WINDOW_START}")"

  local remain_m
  if (( start_m < end_m )); then
    remain_m=$((end_m - now_m))
  else
    # cruza meia-noite
    if (( now_m >= start_m )); then
      remain_m=$((24 * 60 - now_m + end_m))
    else
      remain_m=$((end_m - now_m))
    fi
  fi
  if (( remain_m < 1 )); then
    remain_m=1
  fi
  echo $((remain_m * 60))
}

enforce_backup_window() {
  if [[ "${BACKUP_WINDOW_ENABLED}" != "true" || "${IGNORE_WINDOW}" == "true" ]]; then
    RCLONE_MAX_DURATION_ARGS=()
    return 0
  fi

  if ! in_backup_window; then
    log_warn "Fora da janela ${BACKUP_WINDOW_START}–${BACKUP_WINDOW_END} (agora $(date +%H:%M))"
    log_info "O timer retoma dentro da janela. Force com: sudo ./backup-cloud.sh --ignore-window"
    exit 0
  fi

  local dur="${BACKUP_MAX_DURATION}"
  if [[ -z "${dur}" ]]; then
    dur="$(seconds_until_window_end)s"
  fi
  RCLONE_MAX_DURATION_ARGS=(--max-duration "${dur}" --cutoff-mode soft)
  log_info "Janela ${BACKUP_WINDOW_START}–${BACKUP_WINDOW_END}: rclone para em --max-duration ${dur} (retoma depois)"
}

# Flags de rate-limit / delay (respeitam throttle do Google Drive)
rclone_rate_limit_args() {
  local args=()
  [[ -n "${RCLONE_TRANSFERS}" ]] && args+=(--transfers "${RCLONE_TRANSFERS}")
  [[ -n "${RCLONE_CHECKERS}" ]] && args+=(--checkers "${RCLONE_CHECKERS}")
  [[ -n "${RCLONE_TPSLIMIT}" ]] && args+=(--tpslimit "${RCLONE_TPSLIMIT}")
  [[ -n "${RCLONE_TPSLIMIT_BURST}" ]] && args+=(--tpslimit-burst "${RCLONE_TPSLIMIT_BURST}")
  [[ -n "${RCLONE_DRIVE_PACER_MIN_SLEEP}" ]] && args+=(--drive-pacer-min-sleep "${RCLONE_DRIVE_PACER_MIN_SLEEP}")
  [[ -n "${RCLONE_RETRIES_SLEEP}" ]] && args+=(--retries-sleep "${RCLONE_RETRIES_SLEEP}")
  if [[ ${#args[@]} -gt 0 ]]; then
    printf '%s\n' "${args[@]}"
  fi
}

# true se o exit do rclone foi só limite de duração/transferência (progresso parcial ok)
rclone_partial_ok() {
  local rc="$1"
  local log_file="$2"
  case "${rc}" in
    8|10) return 0 ;;  # max transfer / max duration (versões recentes)
  esac
  if [[ -f "${log_file}" ]] && grep -qE 'max transfer duration reached|MaxDurationReached|max transfer limit reached' "${log_file}"; then
    return 0
  fi
  return 1
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

  local rate_args=()
  mapfile -t rate_args < <(rclone_rate_limit_args)
  if [[ ${#rate_args[@]} -gt 0 ]]; then
    args+=("${rate_args[@]}")
    log_info "Rate-limit: transfers=${RCLONE_TRANSFERS} checkers=${RCLONE_CHECKERS} tpslimit=${RCLONE_TPSLIMIT} burst=${RCLONE_TPSLIMIT_BURST} pacer=${RCLONE_DRIVE_PACER_MIN_SLEEP} retries-sleep=${RCLONE_RETRIES_SLEEP}"
  fi

  if [[ ${#RCLONE_MAX_DURATION_ARGS[@]} -gt 0 ]]; then
    args+=("${RCLONE_MAX_DURATION_ARGS[@]}")
  fi

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

  set +e
  rclone_exec "${args[@]}"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    log_ok "${label} concluído (log: ${log_file})"
    return 0
  fi
  if rclone_partial_ok "${rc}" "${log_file}"; then
    log_ok "${label}: janela/duração esgotada — progresso mantido; continua na próxima execução"
    return 0
  fi
  log_error "${label} falhou (rc=${rc}) — veja ${log_file}"
  return 1
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

  # Canonicalizar (ex.: /media/music/../backup-restic → /media/backup-restic)
  if command -v realpath >/dev/null 2>&1; then
    RESTIC_REPOSITORY="$(realpath -m "${RESTIC_REPOSITORY}")"
  fi

  if [[ ! -d "${RESTIC_REPOSITORY}" ]]; then
    die "Repositório restic inexistente: ${RESTIC_REPOSITORY}
Crie o 1º snapshot: sudo ./backup-restic.sh"
  fi

  maybe_run_restic_first

  local dest="${RCLONE_REMOTE}:${RCLONE_PATH}/${RESTIC_CLOUD_SUBDIR}"
  # sync mantém o repo remoto alinhado (prune local remove packs órfãos)
  # root + conf do BACKUP_USER: pastas do restic são 700 root; OAuth fica no home do usuário
  local saved_mode="${RCLONE_MODE}"
  local saved_run="${RCLONE_RUN_MODE}"
  RCLONE_MODE="sync"
  RCLONE_RUN_MODE="root"
  log_info "Sync do repo restic como root (lê ${RESTIC_REPOSITORY}, OAuth de $(rclone_backup_user))"
  run_rclone_transfer "restic-repo" "${RESTIC_REPOSITORY}" "${dest}" \
    "**/.lock" || {
      RCLONE_MODE="${saved_mode}"
      RCLONE_RUN_MODE="${saved_run}"
      return 1
    }
  RCLONE_MODE="${saved_mode}"
  RCLONE_RUN_MODE="${saved_run}"
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
  if [[ "${BACKUP_WINDOW_ENABLED}" == "true" ]]; then
    echo -e "  Janela:   ${BACKUP_WINDOW_START}–${BACKUP_WINDOW_END}$([[ "${IGNORE_WINDOW}" == "true" ]] && echo ' (ignorada)')"
  fi
  if [[ "${BACKUP_PAYLOAD}" == "zip" ]]; then
    echo -e "  Músicas:  ${BACKUP_MUSIC} (${MUSIC_ROOT})"
    echo -e "  Fotos:    ${BACKUP_PHOTOS} (${PHOTOS_ROOT})"
  fi
  echo

  enforce_backup_window

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
