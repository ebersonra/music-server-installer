#!/usr/bin/env bash
# setup-security.sh — Fail2Ban + unattended-upgrades + restic (snapshots criptografados)
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"
# shellcheck source=services/security.sh
source "${INSTALLER_ROOT}/services/security.sh"

RESTIC_CONF="${STATE_DIR}/restic-backup.conf"
RESTIC_PASS_FILE="${STATE_DIR}/restic.password"
RESTIC_TEMPLATE="${INSTALLER_ROOT}/templates/restic-backup.conf"

DO_FAIL2BAN=true
DO_UNATTENDED=true
DO_RESTIC=true
INSTALL_TIMER=true

usage() {
  cat <<EOF
Uso: sudo ./setup-security.sh [opções]

Segurança “quase profissional” para servidor doméstico:

  1) Fail2Ban          — bloqueia força bruta no SSH
  2) unattended-upgrades — patches de segurança automáticos
  3) restic            — snapshots versionados + criptografados

Opções:
  -y, --yes           Confirmar automaticamente quando possível
  --only-fail2ban     Só Fail2Ban
  --only-updates      Só unattended-upgrades
  --only-restic       Só restic
  --no-timer          Não instalar timer do restic
  -h, --help          Esta ajuda
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=true; shift ;;
      --only-fail2ban)
        DO_FAIL2BAN=true; DO_UNATTENDED=false; DO_RESTIC=false; shift ;;
      --only-updates)
        DO_FAIL2BAN=false; DO_UNATTENDED=true; DO_RESTIC=false; shift ;;
      --only-restic)
        DO_FAIL2BAN=false; DO_UNATTENDED=false; DO_RESTIC=true; shift ;;
      --no-timer) INSTALL_TIMER=false; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

install_restic_pkg() {
  if command -v restic >/dev/null 2>&1; then
    log_ok "restic já instalado: $(restic version 2>/dev/null | head -1)"
    return 0
  fi
  log_step "Instalando restic"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  if ! apt-get install -y -qq restic; then
    die "Falha ao instalar restic (apt)"
  fi
  log_ok "restic instalado"
}

generate_restic_password() {
  if [[ -f "${RESTIC_PASS_FILE}" ]]; then
    log_ok "Senha restic já existe em ${RESTIC_PASS_FILE}"
    if ! confirm "Gerar nova senha (invalida snapshots antigos se mudar o repo)?" "N"; then
      return 0
    fi
  fi
  mkdir -p "${STATE_DIR}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 > "${RESTIC_PASS_FILE}"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40 > "${RESTIC_PASS_FILE}" || true
  fi
  chmod 600 "${RESTIC_PASS_FILE}"
  log_ok "Senha gerada em ${RESTIC_PASS_FILE}"
  echo
  echo -e "${C_YELLOW}Guarde esta senha fora do notebook (papel / gerenciador de senhas).${C_RESET}"
  echo -e "${C_YELLOW}Sem ela, os snapshots restic NÃO podem ser restaurados.${C_RESET}"
  echo
  if confirm "Exibir a senha agora na tela?" "N"; then
    echo -e "${C_BOLD}$(cat "${RESTIC_PASS_FILE}")${C_RESET}"
    echo
  fi
}

configure_restic_repo() {
  echo
  echo -e "${C_BOLD}Repositório restic${C_RESET}"
  echo
  echo -e "Exemplos:"
  echo -e "  ${C_CYAN}/mnt/backup/restic-repo${C_RESET}              (outro HD / pendrive)"
  echo -e "  ${C_CYAN}rclone:gdrive:restic-music-server${C_RESET}  (Google Drive via rclone)"
  echo -e "  ${C_CYAN}sftp:usuario@host:/backups/restic${C_RESET}"
  echo
  echo -e "${C_DIM}Para rclone:, configure antes com: sudo ./setup-cloud-backup.sh${C_RESET}"
  echo

  local default_repo=""
  if [[ -d /mnt/backup ]]; then
    default_repo="/mnt/backup/restic-repo"
  elif command -v rclone >/dev/null 2>&1; then
    default_repo="rclone:gdrive:restic-music-server"
  else
    default_repo="/media/music/../backup-restic"
  fi

  RESTIC_REPOSITORY="$(prompt_input "RESTIC_REPOSITORY" "${default_repo}")"
  [[ -n "${RESTIC_REPOSITORY}" ]] || die "Repositório obrigatório"

  # Repo local: criar diretório
  if [[ "${RESTIC_REPOSITORY}" == /* ]]; then
    mkdir -p "${RESTIC_REPOSITORY}"
  fi

  export RESTIC_REPOSITORY
  export RESTIC_PASSWORD_FILE="${RESTIC_PASS_FILE}"

  if restic cat config >/dev/null 2>&1; then
    log_ok "Repositório restic já inicializado"
  else
    log_step "Inicializando repositório restic (criptografado)"
    restic init || die "Falha em restic init"
    log_ok "Repositório criado"
  fi

  mkdir -p "${STATE_DIR}"
  if [[ -f "${RESTIC_TEMPLATE}" ]]; then
    cp "${RESTIC_TEMPLATE}" "${RESTIC_CONF}"
  else
    touch "${RESTIC_CONF}"
  fi

  _set() {
    local key="$1" val="$2"
    local escaped
    escaped="$(printf '%s' "${val}" | sed 's/[|&]/\\&/g')"
    if grep -qE "^${key}=" "${RESTIC_CONF}"; then
      sed -i "s|^${key}=.*|${key}=\"${escaped}\"|" "${RESTIC_CONF}"
    else
      echo "${key}=\"${val}\"" >> "${RESTIC_CONF}"
    fi
  }

  local schedule
  schedule="$(prompt_input "Horário diário restic (OnCalendar)" "*-*-* 04:00:00")"
  [[ -z "${schedule}" ]] && schedule="*-*-* 04:00:00"

  _set RESTIC_REPOSITORY "${RESTIC_REPOSITORY}"
  _set RESTIC_PASSWORD_FILE "${RESTIC_PASS_FILE}"
  _set BACKUP_MUSIC "true"
  _set BACKUP_PHOTOS "true"
  _set BACKUP_DOWNLOADS "false"
  _set KEEP_DAILY "7"
  _set KEEP_WEEKLY "4"
  _set KEEP_MONTHLY "6"
  _set KEEP_YEARLY "2"
  _set BACKUP_SCHEDULE "${schedule}"
  _set BACKUP_LOG_DIR "${STATE_DIR}/logs"
  chmod 600 "${RESTIC_CONF}"
  log_ok "Config em ${RESTIC_CONF}"
}

install_restic_timer() {
  # shellcheck source=/dev/null
  source "${RESTIC_CONF}"
  local script="${INSTALLER_ROOT}/backup-restic.sh"
  chmod +x "${script}"

  cat > /etc/systemd/system/music-server-restic.service <<EOF
[Unit]
Description=Music Server — snapshot criptografado (restic)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/music-server-restic.timer <<EOF
[Unit]
Description=Timer diário — restic (snapshots)

[Timer]
OnCalendar=${BACKUP_SCHEDULE:-*-*-* 04:00:00}
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now music-server-restic.timer
  log_ok "Timer restic ativo (${BACKUP_SCHEDULE})"
  systemctl list-timers music-server-restic.timer --no-pager 2>/dev/null || true
}

setup_restic() {
  install_restic_pkg
  generate_restic_password
  configure_restic_repo

  if [[ "${INSTALL_TIMER}" == "true" ]]; then
    if confirm "Instalar timer diário do restic?"; then
      install_restic_timer
    fi
  fi

  if confirm "Rodar primeiro snapshot agora?" "S"; then
    "${INSTALLER_ROOT}/backup-restic.sh" || log_warn "Primeiro backup falhou — confira repo/senha/montagem"
  fi
}

main() {
  parse_args "$@"
  require_root
  print_banner

  echo -e "${C_BOLD}Setup de segurança (servidor doméstico)${C_RESET}"
  echo
  echo -e "  ${C_GREEN}1${C_RESET} Fail2Ban — SSH"
  echo -e "  ${C_GREEN}2${C_RESET} unattended-upgrades — patches automáticos"
  echo -e "  ${C_GREEN}3${C_RESET} restic — backups versionados + criptografia"
  echo

  if [[ "${DO_FAIL2BAN}" == "true" ]]; then
    if confirm "Instalar/configurar Fail2Ban?"; then
      install_fail2ban
    fi
  fi

  if [[ "${DO_UNATTENDED}" == "true" ]]; then
    if confirm "Ativar unattended-upgrades (só security)?"; then
      install_unattended_upgrades
    fi
  fi

  if [[ "${DO_RESTIC}" == "true" ]]; then
    if confirm "Configurar restic (snapshots criptografados)?"; then
      setup_restic
    fi
  fi

  echo
  log_ok "Setup de segurança concluído"
  echo
  echo -e "${C_DIM}Fail2Ban:   sudo fail2ban-client status sshd${C_RESET}"
  echo -e "${C_DIM}Updates:    sudo unattended-upgrade --dry-run${C_RESET}"
  echo -e "${C_DIM}restic:     sudo ./backup-restic.sh${C_RESET}"
  echo -e "${C_DIM}Guia:       docs/security.md${C_RESET}"
  echo
}

main "$@"
