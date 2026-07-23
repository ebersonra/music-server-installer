#!/usr/bin/env bash
# setup-cloud-backup.sh — Instala rclone, configura remote e agenda backup
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"

CLOUD_CONF="${STATE_DIR}/cloud-backup.conf"
TEMPLATE="${INSTALLER_ROOT}/templates/cloud-backup.conf"

usage() {
  cat <<EOF
Uso: sudo ./setup-cloud-backup.sh [opções]

Instala rclone, guia a conta na nuvem (Google Drive, etc.) e agenda
backup diário do HD externo via systemd timer.

Opções:
  -y, --yes          Confirmar automaticamente quando possível
  --no-timer         Não instalar o timer systemd
  --refresh-timer    Só atualiza conf (janela/rate-limit) + reinstala o timer
  -h, --help         Esta ajuda
EOF
}

INSTALL_TIMER=true
REFRESH_TIMER_ONLY=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=true; shift ;;
      --no-timer) INSTALL_TIMER=false; shift ;;
      --refresh-timer) REFRESH_TIMER_ONLY=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

install_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    log_ok "rclone já instalado: $(rclone version 2>/dev/null | head -1)"
    return 0
  fi

  log_step "Instalando rclone"
  export DEBIAN_FRONTEND=noninteractive
  # Script oficial (versão atualizada; apt costuma ficar atrasado)
  if curl -fsSL https://rclone.org/install.sh | bash; then
    log_ok "rclone instalado via script oficial"
  else
    log_warn "Falha no script oficial — tentando apt"
    apt-get update -qq
    apt-get install -y -qq rclone || die "Não foi possível instalar rclone"
  fi
  command -v rclone >/dev/null || die "rclone não encontrado no PATH"
}

pick_backup_user() {
  if load_state; then
    BACKUP_USER="${TARGET_USER}"
    log_ok "Usuário do backup: ${BACKUP_USER} (do install.state)"
  else
    select_user
    BACKUP_USER="${TARGET_USER}"
  fi
  if [[ -z "${BACKUP_USER}" ]] || ! id "${BACKUP_USER}" &>/dev/null; then
    die "Usuário inválido para rclone/OAuth"
  fi
}

configure_rclone_remote() {
  local home
  home="$(getent passwd "${BACKUP_USER}" | cut -d: -f6)"
  local conf="${home}/.config/rclone/rclone.conf"

  mkdir -p "${home}/.config/rclone"
  chown -R "${BACKUP_USER}:${BACKUP_USER}" "${home}/.config"

  echo
  echo -e "${C_BOLD}Configurar remote rclone${C_RESET}"
  echo
  echo -e "Vai abrir o assistente interativo. Para Google Drive:"
  echo -e "  1) n  → New remote"
  echo -e "  2) name → ${C_CYAN}gdrive${C_RESET} (ou outro nome)"
  echo -e "  3) Storage → ${C_CYAN}Google Drive${C_RESET} (número da lista)"
  echo -e "  4) client_id / secret → Enter (defaults ok para uso pessoal)"
  echo -e "  5) scope → ${C_CYAN}1${C_RESET} (Full access) ou drive.file"
  echo -e "  6) root_folder_id → Enter"
  echo -e "  7) service_account → n"
  echo -e "  8) Auto config → ${C_CYAN}y${C_RESET} (abre o navegador; no servidor headless use n e cole o token)"
  echo -e "  9) Shared drive → n (a menos que use Shared Drive)"
  echo -e " 10) Keep remote → y"
  echo
  echo -e "${C_DIM}Outros provedores: Dropbox, OneDrive, Mega, S3, etc. — mesma ideia.${C_RESET}"
  echo

  if [[ -f "${conf}" ]] && rclone --config "${conf}" listremotes 2>/dev/null | grep -q .; then
    echo -e "Remotes existentes:"
    rclone --config "${conf}" listremotes 2>/dev/null || true
    echo
    if confirm "Já existe remote. Abrir rclone config mesmo assim?" "N"; then
      if command -v runuser >/dev/null 2>&1; then
        runuser -u "${BACKUP_USER}" -- rclone config
      else
        sudo -u "${BACKUP_USER}" -- rclone config
      fi
    fi
  else
    if ! confirm "Iniciar rclone config agora?"; then
      die "Sem remote configurado o backup não funciona. Rode depois: sudo -u ${BACKUP_USER} rclone config"
    fi
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "${BACKUP_USER}" -- rclone config
    else
      sudo -u "${BACKUP_USER}" -- rclone config
    fi
  fi

  local remotes
  if command -v runuser >/dev/null 2>&1; then
    remotes="$(runuser -u "${BACKUP_USER}" -- rclone listremotes 2>/dev/null | sed 's/:$//' || true)"
  else
    remotes="$(sudo -u "${BACKUP_USER}" -- rclone listremotes 2>/dev/null | sed 's/:$//' || true)"
  fi
  if [[ -z "${remotes}" ]]; then
    die "Nenhum remote rclone encontrado. Refaça: sudo -u ${BACKUP_USER} rclone config"
  fi

  echo
  echo -e "${C_BOLD}Remotes disponíveis:${C_RESET}"
  local i=1
  local arr=()
  while IFS= read -r r; do
    [[ -z "${r}" ]] && continue
    arr+=("${r}")
    echo -e "  ${i}) ${r}"
    i=$((i + 1))
  done <<< "${remotes}"

  local choice
  choice="$(prompt_input "Escolha o remote (número)" "1")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#arr[@]} )); then
    die "Escolha inválida"
  fi
  RCLONE_REMOTE="${arr[$((choice - 1))]}"
  log_ok "Remote selecionado: ${RCLONE_REMOTE}"
}

write_cloud_conf() {
  mkdir -p "${STATE_DIR}"
  local path_default="music-server-backup"
  RCLONE_PATH="$(prompt_input "Pasta no remote" "${path_default}")"
  [[ -z "${RCLONE_PATH}" ]] && RCLONE_PATH="${path_default}"

  echo
  echo -e "${C_BOLD}O que enviar para a nuvem?${C_RESET}"
  echo -e "  ${C_CYAN}1)${C_RESET} restic — snapshots criptografados (recomendado; economiza espaço)"
  echo -e "  ${C_CYAN}2)${C_RESET} zip    — arquivos *.zip datados de músicas/fotos"
  echo
  echo -e "${C_DIM}Não espelhamos arquivos soltos: eles já estão no HD / Google Fotos.${C_RESET}"
  local payload_choice
  payload_choice="$(prompt_input "Escolha (1/2)" "1")"
  case "${payload_choice}" in
    2) BACKUP_PAYLOAD="zip" ;;
    *) BACKUP_PAYLOAD="restic" ;;
  esac
  log_ok "Payload: ${BACKUP_PAYLOAD}"

  local mode_default="copy"
  echo
  echo -e "${C_DIM}copy = sobe sem apagar outros arquivos no remote${C_RESET}"
  echo -e "${C_DIM}sync = espelha (no modo restic o repo usa sync automaticamente)${C_RESET}"
  RCLONE_MODE="$(prompt_input "Modo rclone (copy/sync)" "${mode_default}")"
  [[ "${RCLONE_MODE}" != "sync" ]] && RCLONE_MODE="copy"

  echo
  echo -e "${C_BOLD}Janela horária (upload parcial)${C_RESET}"
  echo -e "${C_DIM}Útil para ~100+ GiB no Google Drive: sobe só à noite/madrugada e retoma no dia seguinte.${C_RESET}"
  if confirm "Limitar upload a uma janela horária (ex.: 17:00–06:00)?" "S"; then
    BACKUP_WINDOW_ENABLED=true
    BACKUP_WINDOW_START="$(prompt_input "Início da janela (HH:MM)" "17:00")"
    BACKUP_WINDOW_END="$(prompt_input "Fim da janela (HH:MM)" "06:00")"
    [[ -z "${BACKUP_WINDOW_START}" ]] && BACKUP_WINDOW_START="17:00"
    [[ -z "${BACKUP_WINDOW_END}" ]] && BACKUP_WINDOW_END="06:00"
    schedule_default="*-*-* ${BACKUP_WINDOW_START}:00"
    # OnCalendar quer HH:MM:SS
    if [[ "${BACKUP_WINDOW_START}" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
      schedule_default="*-*-* ${BACKUP_WINDOW_START}:00"
    else
      schedule_default="*-*-* 17:00:00"
    fi
  else
    BACKUP_WINDOW_ENABLED=false
    BACKUP_WINDOW_START="17:00"
    BACKUP_WINDOW_END="06:00"
    schedule_default="*-*-* 03:00:00"
  fi

  BACKUP_SCHEDULE="$(prompt_input "Horário do timer (OnCalendar)" "${schedule_default}")"
  [[ -z "${BACKUP_SCHEDULE}" ]] && BACKUP_SCHEDULE="${schedule_default}"

  if [[ -f "${TEMPLATE}" ]]; then
    cp "${TEMPLATE}" "${CLOUD_CONF}"
  else
    touch "${CLOUD_CONF}"
  fi

  # Atualizar chaves com sed
  _set_conf() {
    local key="$1" val="$2"
    # Escapar para sed (delimitador |)
    local escaped
    escaped="$(printf '%s' "${val}" | sed 's/[|&]/\\&/g')"
    if grep -qE "^${key}=" "${CLOUD_CONF}"; then
      sed -i "s|^${key}=.*|${key}=\"${escaped}\"|" "${CLOUD_CONF}"
    else
      echo "${key}=\"${val}\"" >> "${CLOUD_CONF}"
    fi
  }

  _set_conf RCLONE_REMOTE "${RCLONE_REMOTE}"
  _set_conf RCLONE_PATH "${RCLONE_PATH}"
  _set_conf BACKUP_PAYLOAD "${BACKUP_PAYLOAD}"
  _set_conf RCLONE_MODE "${RCLONE_MODE}"
  _set_conf BACKUP_SCHEDULE "${BACKUP_SCHEDULE}"
  _set_conf BACKUP_WINDOW_ENABLED "${BACKUP_WINDOW_ENABLED}"
  _set_conf BACKUP_WINDOW_START "${BACKUP_WINDOW_START}"
  _set_conf BACKUP_WINDOW_END "${BACKUP_WINDOW_END}"
  _set_conf BACKUP_MAX_DURATION ""
  _set_conf BACKUP_USER "${BACKUP_USER}"
  _set_conf BACKUP_MUSIC "true"
  _set_conf BACKUP_PHOTOS "true"
  _set_conf BACKUP_DOWNLOADS "false"
  _set_conf RUN_RESTIC_FIRST "true"
  _set_conf RESTIC_CLOUD_SUBDIR "restic-repo"
  _set_conf ZIP_STAGING_DIR ""
  _set_conf ZIP_KEEP_LOCAL "1"
  _set_conf ZIP_KEEP_REMOTE "3"
  _set_conf ZIP_COMPRESSION "0"
  _set_conf BACKUP_LOG_DIR "${STATE_DIR}/logs"
  _set_conf RCLONE_TRANSFERS "2"
  _set_conf RCLONE_CHECKERS "4"
  _set_conf RCLONE_TPSLIMIT "4"
  _set_conf RCLONE_TPSLIMIT_BURST "1"
  _set_conf RCLONE_DRIVE_PACER_MIN_SLEEP "200ms"
  _set_conf RCLONE_RETRIES_SLEEP "30s"
  _set_conf RCLONE_EXTRA_OPTS "--fast-list --retries 5 --low-level-retries 10"

  chmod 600 "${CLOUD_CONF}"
  log_ok "Config salva em ${CLOUD_CONF}"

  if [[ "${BACKUP_PAYLOAD}" == "restic" ]]; then
    echo
    if [[ ! -f "${STATE_DIR}/restic-backup.conf" ]]; then
      log_warn "restic ainda não configurado"
      echo -e "  Rode: ${C_CYAN}sudo ./setup-security.sh --only-restic${C_RESET}"
      echo -e "  Use repositório ${C_BOLD}local${C_RESET} (ex.: /mnt/backup/restic-repo) para o cloud backup"
      echo -e "  espelhar o repo; ou ${C_BOLD}rclone:gdrive:...${C_RESET} para restic ir direto à nuvem."
    else
      log_ok "restic já configurado — backup-cloud.sh sincronizará o repositório"
    fi
  fi
}

install_systemd_timer() {
  local script="${INSTALLER_ROOT}/backup-cloud.sh"
  if [[ ! -x "${script}" ]]; then
    chmod +x "${script}"
  fi

  # shellcheck source=/dev/null
  source "${CLOUD_CONF}"

  # Timeout = duração da janela + 1h de folga (rclone --max-duration + transfers em voo)
  local timeout="infinity"
  if [[ "${BACKUP_WINDOW_ENABLED:-false}" == "true" ]]; then
    local start_m end_m remain_m hours
    start_m="$(_hhmm_to_minutes_setup "${BACKUP_WINDOW_START:-17:00}")"
    end_m="$(_hhmm_to_minutes_setup "${BACKUP_WINDOW_END:-06:00}")"
    if (( start_m == end_m )); then
      remain_m=$((24 * 60))
    elif (( start_m < end_m )); then
      remain_m=$((end_m - start_m))
    else
      remain_m=$((24 * 60 - start_m + end_m))
    fi
    hours=$((remain_m / 60 + 1))
    (( hours < 2 )) && hours=2
    timeout="${hours}h"
  fi

  cat > /etc/systemd/system/music-server-cloud-backup.service <<EOF
[Unit]
Description=Music Server — backup HD externo para nuvem (rclone)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=${timeout}

[Install]
WantedBy=multi-user.target
EOF

  local delay="10m"
  if [[ "${BACKUP_WINDOW_ENABLED:-false}" == "true" ]]; then
    delay="2m"
  fi

  cat > /etc/systemd/system/music-server-cloud-backup.timer <<EOF
[Unit]
Description=Timer diário — backup HD → nuvem

[Timer]
OnCalendar=${BACKUP_SCHEDULE:-*-*-* 17:00:00}
Persistent=true
RandomizedDelaySec=${delay}

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now music-server-cloud-backup.timer
  log_ok "Timer ativo: music-server-cloud-backup.timer (${BACKUP_SCHEDULE})"
  if [[ "${BACKUP_WINDOW_ENABLED:-false}" == "true" ]]; then
    log_info "Janela: ${BACKUP_WINDOW_START:-17:00}–${BACKUP_WINDOW_END:-06:00} (upload parcial; retoma no dia seguinte)"
    log_info "Timeout systemd: ${timeout}"
  fi
  systemctl list-timers music-server-cloud-backup.timer --no-pager 2>/dev/null || true
}

# HH:MM → minutos (helper local do setup; espelha backup-cloud.sh)
_hhmm_to_minutes_setup() {
  local t="$1"
  local h m
  if ! [[ "${t}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    echo 0
    return 0
  fi
  h="${BASH_REMATCH[1]}"
  m="${BASH_REMATCH[2]}"
  h=$((10#${h}))
  m=$((10#${m}))
  echo $((h * 60 + m))
}

# Atualiza janela 17:00–06:00 + rate-limit na conf existente (sem reconfigurar remote)
refresh_window_and_rate_limit() {
  if [[ ! -f "${CLOUD_CONF}" ]]; then
    die "Config não encontrada: ${CLOUD_CONF}
Execute o setup completo primeiro: sudo ./setup-cloud-backup.sh"
  fi

  _set_conf() {
    local key="$1" val="$2"
    local escaped
    escaped="$(printf '%s' "${val}" | sed 's/[|&]/\\&/g')"
    if grep -qE "^${key}=" "${CLOUD_CONF}"; then
      sed -i "s|^${key}=.*|${key}=\"${escaped}\"|" "${CLOUD_CONF}"
    else
      echo "${key}=\"${val}\"" >> "${CLOUD_CONF}"
    fi
  }

  log_step "Atualizando janela e rate-limit em ${CLOUD_CONF}"
  _set_conf BACKUP_WINDOW_ENABLED "true"
  _set_conf BACKUP_WINDOW_START "17:00"
  _set_conf BACKUP_WINDOW_END "06:00"
  _set_conf BACKUP_SCHEDULE "*-*-* 17:00:00"
  _set_conf BACKUP_MAX_DURATION ""
  _set_conf RCLONE_TRANSFERS "2"
  _set_conf RCLONE_CHECKERS "4"
  _set_conf RCLONE_TPSLIMIT "4"
  _set_conf RCLONE_TPSLIMIT_BURST "1"
  _set_conf RCLONE_DRIVE_PACER_MIN_SLEEP "200ms"
  _set_conf RCLONE_RETRIES_SLEEP "30s"
  # Remove transfers/tpslimit antigos de EXTRA_OPTS (agora vêm das chaves acima)
  _set_conf RCLONE_EXTRA_OPTS "--fast-list --retries 5 --low-level-retries 10"
  chmod 600 "${CLOUD_CONF}"
  log_ok "Janela 17:00–06:00 + rate-limit aplicados"
}

main() {
  parse_args "$@"
  require_root
  print_banner

  if [[ "${REFRESH_TIMER_ONLY}" == "true" ]]; then
    echo -e "${C_BOLD}Refresh timer / janela / rate-limit${C_RESET}"
    echo
    refresh_window_and_rate_limit
    install_systemd_timer
    echo
    log_ok "Timer atualizado"
    echo -e "${C_DIM}Próximo disparo:${C_RESET}"
    systemctl list-timers music-server-cloud-backup.timer --no-pager 2>/dev/null || true
    echo -e "${C_DIM}Config: ${CLOUD_CONF}${C_RESET}"
    echo
    return 0
  fi

  echo -e "${C_BOLD}Setup backup na nuvem (rclone)${C_RESET}"
  echo
  echo -e "Cópia de segurança compacta → Google Drive / outro remote."
  echo -e "${C_DIM}Payload: snapshots restic (recomendado) ou *.zip — não espelha arquivos soltos.${C_RESET}"
  echo

  install_rclone
  pick_backup_user
  configure_rclone_remote
  write_cloud_conf

  mkdir -p "${STATE_DIR}/logs"
  if [[ -n "${BACKUP_USER:-}" ]]; then
    chown "${BACKUP_USER}:${BACKUP_USER}" "${STATE_DIR}/logs" 2>/dev/null || true
    chmod 750 "${STATE_DIR}/logs" 2>/dev/null || true
  fi

  if [[ "${INSTALL_TIMER}" == "true" ]]; then
    if confirm "Instalar backup automático diário (systemd timer)?"; then
      install_systemd_timer
    else
      log_info "Timer pulado. Rode manualmente: sudo ./backup-cloud.sh"
    fi
  fi

  echo
  if confirm "Rodar um dry-run agora?" "S"; then
    "${INSTALLER_ROOT}/backup-cloud.sh" --dry-run || log_warn "Dry-run retornou erro — confira remote/paths"
  fi

  echo
  log_ok "Setup concluído"
  echo
  echo -e "${C_DIM}Manual:     sudo ./backup-cloud.sh${C_RESET}"
  echo -e "${C_DIM}Dry-run:    sudo ./backup-cloud.sh --dry-run${C_RESET}"
  echo -e "${C_DIM}Só restic:  sudo ./backup-cloud.sh --payload restic${C_RESET}"
  echo -e "${C_DIM}Só zip:     sudo ./backup-cloud.sh --payload zip${C_RESET}"
  echo -e "${C_DIM}Forçar agora: sudo ./backup-cloud.sh --ignore-window${C_RESET}"
  echo -e "${C_DIM}Refresh timer: sudo ./setup-cloud-backup.sh --refresh-timer${C_RESET}"
  echo -e "${C_DIM}Config:     ${CLOUD_CONF}${C_RESET}"
  echo -e "${C_DIM}Logs:       ${STATE_DIR}/logs/${C_RESET}"
  echo -e "${C_DIM}Timer:      systemctl status music-server-cloud-backup.timer${C_RESET}"
  echo -e "${C_DIM}Guia:       docs/cloud-backup.md${C_RESET}"
  echo
}

main "$@"
