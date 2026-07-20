#!/usr/bin/env bash
# common.sh — Funções compartilhadas do Music Server Installer
# shellcheck disable=SC2034,SC2154

set -euo pipefail

# -----------------------------------------------------------------------------
# Bootstrap: carregar config se ainda não carregado
# -----------------------------------------------------------------------------
_common_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${_common_self}/config.sh"
INSTALLER_ROOT="${_common_self}"

# -----------------------------------------------------------------------------
# Logging / UI
# -----------------------------------------------------------------------------
log_info()  { echo -e "${C_CYAN}ℹ${C_RESET}  $*"; }
log_ok()    { echo -e "${C_GREEN}✓${C_RESET}  $*"; }
log_warn()  { echo -e "${C_YELLOW}⚠${C_RESET}  $*"; }
log_error() { echo -e "${C_RED}✗${C_RESET}  $*" >&2; }
log_step()  { echo -e "\n${C_BOLD}${C_BLUE}▶${C_RESET} ${C_BOLD}$*${C_RESET}"; }

die() {
  log_error "$*"
  exit 1
}

print_banner() {
  clear 2>/dev/null || true
  echo -e "${C_CYAN}"
  cat <<'EOF'
====================================
      Music Server Installer
====================================
EOF
  echo -e "${C_RESET}"
  echo -e "${C_DIM}Versão ${INSTALLER_VERSION} · Ubuntu / Debian${C_RESET}"
  echo
}

print_separator() {
  echo -e "${C_DIM}------------------------------------${C_RESET}"
}

confirm() {
  local prompt="${1:-Continuar?}"
  local default="${2:-S}"
  local reply

  if [[ "${ASSUME_YES}" == "true" ]]; then
    return 0
  fi

  if [[ "${default}" =~ ^[Ss]$ ]]; then
    read -r -p "$(echo -e "${prompt} ${C_DIM}(S/n)${C_RESET}: ")" reply || true
    reply="${reply:-S}"
  else
    read -r -p "$(echo -e "${prompt} ${C_DIM}(s/N)${C_RESET}: ")" reply || true
    reply="${reply:-N}"
  fi

  [[ "${reply}" =~ ^[SsYy]$ ]]
}

prompt_input() {
  local prompt="$1"
  local default="${2:-}"
  local result

  if [[ -n "${default}" ]]; then
    read -r -p "$(echo -e "${prompt} ${C_DIM}[${default}]${C_RESET}: ")" result || true
    echo "${result:-$default}"
  else
    read -r -p "$(echo -e "${prompt}: ")" result || true
    echo "${result}"
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Este script precisa ser executado como root. Use: sudo $0"
  fi
}

# -----------------------------------------------------------------------------
# Detecção de sistema
# -----------------------------------------------------------------------------
detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    die "Sistema operacional não suportado (sem /etc/os-release)."
  fi

  # shellcheck source=/dev/null
  source /etc/os-release

  local id="${ID:-}"
  local version_id="${VERSION_ID:-}"
  local supported=false

  for d in "${SUPPORTED_DISTROS[@]}"; do
    if [[ "${id}" == "${d}" ]]; then
      supported=true
      break
    fi
  done

  if [[ "${supported}" != "true" ]]; then
    die "Distribuição '${id}' não suportada. Use Ubuntu ou Debian."
  fi

  OS_ID="${id}"
  OS_VERSION="${version_id}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  # Checagem mínima de versão (best-effort)
  if command -v dpkg >/dev/null 2>&1; then
    if [[ "${id}" == "ubuntu" && -n "${version_id}" ]]; then
      if ! dpkg --compare-versions "${version_id}" ge "${MIN_UBUNTU_VERSION}"; then
        die "Ubuntu ${version_id} não suportado (mínimo: ${MIN_UBUNTU_VERSION})"
      fi
    fi
    if [[ "${id}" == "debian" && -n "${version_id}" ]]; then
      if ! dpkg --compare-versions "${version_id}" ge "${MIN_DEBIAN_VERSION}"; then
        die "Debian ${version_id} não suportado (mínimo: ${MIN_DEBIAN_VERSION})"
      fi
    fi
  fi

  log_ok "Sistema detectado: ${PRETTY_NAME:-$id $version_id} (${OS_ARCH})"
}

# -----------------------------------------------------------------------------
# Detecção de usuários
# -----------------------------------------------------------------------------
detect_users() {
  local candidates=()
  local u

  # Usuário que invocou sudo
  if [[ -n "${SUDO_USER:-}" ]] && id "${SUDO_USER}" &>/dev/null; then
    candidates+=("${SUDO_USER}")
  fi

  # Usuários com UID >= 1000 (exceto nobody)
  while IFS=: read -r u _ uid _ _ home _; do
    if [[ "${uid}" -ge 1000 && "${uid}" -lt 65534 && -d "${home}" ]]; then
      local already=false
      for c in "${candidates[@]:-}"; do
        [[ "${c}" == "${u}" ]] && already=true && break
      done
      [[ "${already}" == "false" ]] && candidates+=("${u}")
    fi
  done < /etc/passwd

  DETECTED_USERS=("${candidates[@]}")
}

select_user() {
  detect_users

  if [[ ${#DETECTED_USERS[@]} -eq 0 ]]; then
    die "Nenhum usuário interativo encontrado no sistema."
  fi

  echo -e "${C_BOLD}Usuário do Ubuntu:${C_RESET}"
  echo

  if [[ ${#DETECTED_USERS[@]} -eq 1 ]]; then
    echo -e "  ${C_GREEN}${DETECTED_USERS[0]}${C_RESET}"
    echo
    if confirm "Confirmar?"; then
      TARGET_USER="${DETECTED_USERS[0]}"
    else
      die "Instalação cancelada."
    fi
  else
    local i=1
    for u in "${DETECTED_USERS[@]}"; do
      echo "  [${i}] ${u}"
      i=$((i + 1))
    done
    echo
    local choice
    choice="$(prompt_input "Escolha o usuário" "1")"
    if ! [[ "${choice}" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#DETECTED_USERS[@]} )); then
      die "Opção inválida."
    fi
    TARGET_USER="${DETECTED_USERS[$((choice - 1))]}"
  fi

  TARGET_UID="$(id -u "${TARGET_USER}")"
  TARGET_GID="$(id -g "${TARGET_USER}")"
  TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
  QBITTORRENT_CONFIG_DIR="${TARGET_HOME}/.config/qBittorrent"

  if [[ ! -d "${TARGET_HOME}" ]]; then
    die "Home do usuário '${TARGET_USER}' não encontrado: ${TARGET_HOME}"
  fi

  log_ok "Usuário selecionado: ${TARGET_USER} (uid=${TARGET_UID}, gid=${TARGET_GID})"
}

# -----------------------------------------------------------------------------
# Detecção de discos
# -----------------------------------------------------------------------------
# Preenche arrays: DISK_DEVICES[], DISK_LABELS[], DISK_FSTYPES[], DISK_SIZES[], DISK_MOUNTS[]
detect_disks() {
  DISK_DEVICES=()
  DISK_LABELS=()
  DISK_FSTYPES=()
  DISK_SIZES=()
  DISK_MOUNTS=()

  local name fstype size label mountpoint

  # -P: NAME="..." FSTYPE="..." (labels com espaços seguros)
  # Extraímos com sed em vez de eval
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    name="$(printf '%s\n' "${line}" | sed -n 's/.*NAME="\([^"]*\)".*/\1/p')"
    fstype="$(printf '%s\n' "${line}" | sed -n 's/.*FSTYPE="\([^"]*\)".*/\1/p')"
    size="$(printf '%s\n' "${line}" | sed -n 's/.*SIZE="\([^"]*\)".*/\1/p')"
    label="$(printf '%s\n' "${line}" | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p')"
    mountpoint="$(printf '%s\n' "${line}" | sed -n 's/.*MOUNTPOINT="\([^"]*\)".*/\1/p')"

    [[ -z "${name}" || -z "${fstype}" ]] && continue
    [[ "${name}" =~ ^/dev/(loop|ram|sr|fd) ]] && continue
    [[ "${fstype}" == "iso9660" || "${fstype}" == "squashfs" ]] && continue
    [[ "${mountpoint}" == "/" || "${mountpoint}" == "/boot" || "${mountpoint}" == "/boot/efi" ]] && continue

    DISK_DEVICES+=("${name}")
    DISK_FSTYPES+=("${fstype}")
    DISK_SIZES+=("${size:-?}")
    if [[ -z "${label}" ]]; then
      DISK_LABELS+=("$(basename "${name}")")
    else
      DISK_LABELS+=("${label}")
    fi
    DISK_MOUNTS+=("${mountpoint:--}")
  done < <(lsblk -lnpP -o NAME,FSTYPE,SIZE,LABEL,MOUNTPOINT 2>/dev/null)
}

select_disk() {
  detect_disks

  echo -e "${C_BOLD}Detectando discos...${C_RESET}"
  echo

  if [[ ${#DISK_DEVICES[@]} -eq 0 ]]; then
    log_warn "Nenhuma partição secundária detectada."
    echo
    echo "Opções:"
    echo "  [1] Usar caminho local (ex.: /home/${SUDO_USER:-user}/Musicas)"
    echo "  [2] Cancelar"
    echo
    local choice
    choice="$(prompt_input "Escolha" "1")"
    if [[ "${choice}" != "1" ]]; then
      die "Instalação cancelada."
    fi
    local custom
    local default_music="/home/${SUDO_USER:-$(logname 2>/dev/null || echo user)}/Musicas"
    custom="$(prompt_input "Caminho para a biblioteca de músicas" "${default_music}")"
    MOUNT_POINT="$(dirname "${custom}")"
    MUSIC_ROOT="${custom}"
    DISK_DEVICE="local"
    DISK_LABEL="local"
    DISK_FSTYPE="local"
    DISK_SIZE="-"
    return 0
  fi

  local i
  for i in "${!DISK_DEVICES[@]}"; do
    local mp_info=""
    if [[ "${DISK_MOUNTS[$i]}" != "-" ]]; then
      mp_info=" → ${DISK_MOUNTS[$i]}"
    fi
    echo -e "  [$((i + 1))] ${C_BOLD}${DISK_LABELS[$i]}${C_RESET} (${DISK_FSTYPES[$i]}) - ${DISK_SIZES[$i]}${C_DIM}${mp_info}${C_RESET}"
  done
  echo
  echo "  [0] Usar caminho local (sem montar disco externo)"
  echo

  local choice
  choice="$(prompt_input "Escolha o disco" "1")"

  if [[ "${choice}" == "0" ]]; then
    local custom
    local default_music="/home/${SUDO_USER:-$(logname 2>/dev/null || echo user)}/Musicas"
    custom="$(prompt_input "Caminho para a biblioteca de músicas" "${default_music}")"
    MUSIC_ROOT="${custom}"
    MOUNT_POINT="$(dirname "${custom}")"
    DISK_DEVICE="local"
    DISK_LABEL="local"
    DISK_FSTYPE="local"
    DISK_SIZE="-"
    return 0
  fi

  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#DISK_DEVICES[@]} )); then
    die "Opção de disco inválida."
  fi

  local idx=$((choice - 1))
  DISK_DEVICE="${DISK_DEVICES[$idx]}"
  DISK_LABEL="${DISK_LABELS[$idx]}"
  DISK_FSTYPE="${DISK_FSTYPES[$idx]}"
  DISK_SIZE="${DISK_SIZES[$idx]}"

  # Se já montado, validar / oferecer remount canônico
  if [[ "${DISK_MOUNTS[$idx]}" != "-" ]]; then
    local current_mp="${DISK_MOUNTS[$idx]}"
    if declare -f is_critical_mount_point >/dev/null && is_critical_mount_point "${current_mp}"; then
      die "Disco montado em path crítico (${current_mp}). Escolha outro disco ou desmonte antes."
    fi
    # Mounts do desktop (/media/...) são frágeis no boot — preferir /mnt/musicas
    if [[ "${current_mp}" == /media/* ]]; then
      log_warn "Disco montado pelo desktop em ${current_mp}"
      if confirm "Remontar em /mnt/musicas com permissões do instalador?"; then
        MOUNT_POINT="/mnt/musicas"
        # configure_ntfs_mount fará umount + mount
      else
        MOUNT_POINT="${current_mp}"
        log_warn "Reutilizando ${MOUNT_POINT} (fstab pode não ser gerenciado)"
      fi
    else
      MOUNT_POINT="${current_mp}"
      log_ok "Disco já montado em ${MOUNT_POINT}"
    fi
    if declare -f validate_mount_point >/dev/null; then
      # /media/... pode passar se não estiver na lista crítica; fstab cuidará
      if [[ "${MOUNT_POINT}" != /media/* ]]; then
        validate_mount_point "${MOUNT_POINT}"
      fi
    fi
  else
    MOUNT_POINT="$(prompt_input "Ponto de montagem" "/mnt/musicas")"
    if declare -f validate_mount_point >/dev/null; then
      validate_mount_point "${MOUNT_POINT}"
    fi
  fi

  MUSIC_ROOT="${MOUNT_POINT}/Musicas"
  log_ok "Disco selecionado: ${DISK_LABEL} (${DISK_DEVICE}, ${DISK_FSTYPE}, ${DISK_SIZE})"
}

# -----------------------------------------------------------------------------
# Checklist de serviços
# -----------------------------------------------------------------------------
select_services() {
  echo -e "${C_BOLD}Instalar:${C_RESET}"
  echo

  local services=("Plex" "Lidarr" "Prowlarr" "qBittorrent")
  local flags=(INSTALL_PLEX INSTALL_LIDARR INSTALL_PROWLARR INSTALL_QBITTORRENT)
  local selected=(true true true true)
  local i

  for i in "${!services[@]}"; do
    echo -e "  ${C_GREEN}[✓]${C_RESET} ${services[$i]}"
  done
  echo
  echo -e "${C_DIM}Pressione Enter para instalar todos, ou informe números para desmarcar${C_RESET}"
  echo -e "${C_DIM}(ex.: 1 3 = desmarcar Plex e Prowlarr)${C_RESET}"
  echo

  local input
  input="$(prompt_input "Desmarcar serviços (números)" "")"

  if [[ -n "${input}" ]]; then
    for num in ${input}; do
      if [[ "${num}" =~ ^[1-4]$ ]]; then
        selected[$((num - 1))]=false
      fi
    done
  fi

  INSTALL_PLEX="${selected[0]}"
  INSTALL_LIDARR="${selected[1]}"
  INSTALL_PROWLARR="${selected[2]}"
  INSTALL_QBITTORRENT="${selected[3]}"

  echo
  for i in "${!services[@]}"; do
    if [[ "${selected[$i]}" == "true" ]]; then
      echo -e "  ${C_GREEN}[✓]${C_RESET} ${services[$i]}"
    else
      echo -e "  ${C_DIM}[ ]${C_RESET} ${services[$i]}"
    fi
  done
  echo

  local any=false
  for s in "${selected[@]}"; do
    [[ "${s}" == "true" ]] && any=true
  done
  if [[ "${any}" != "true" ]]; then
    die "Nenhum serviço selecionado. Instalação cancelada."
  fi
}

# -----------------------------------------------------------------------------
# Rede
# -----------------------------------------------------------------------------
get_local_ip() {
  local ip=""
  # Preferir IP da rota default (mais confiável que hostname -I)
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  # Filtrar link-local
  if [[ "${ip}" =~ ^169\.254\. ]]; then
    ip=""
  fi
  echo "${ip:-127.0.0.1}"
}

# -----------------------------------------------------------------------------
# Sistema: atualização e dependências
# -----------------------------------------------------------------------------
update_system() {
  if [[ "${SKIP_SYSTEM_UPDATE}" == "true" ]]; then
    log_warn "Pulando atualização do sistema (SKIP_SYSTEM_UPDATE)."
    return 0
  fi
  log_step "Atualizando Ubuntu/Debian"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -y -qq
  log_ok "Sistema atualizado"
}

install_dependencies() {
  log_step "Instalando dependências"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq "${COMMON_DEPS[@]}"
  log_ok "Dependências instaladas"
}

# -----------------------------------------------------------------------------
# Pastas da biblioteca
# -----------------------------------------------------------------------------
create_music_folders() {
  log_step "Criando pastas"

  MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
  DOWNLOADS_DIR="${MUSIC_ROOT}/Downloads"
  INCOMPLETE_DIR="${MUSIC_ROOT}/Downloads/Incomplete"

  local dirs=(
    "${MUSIC_ROOT}"
    "${MUSIC_ROOT}/Artistas"
    "${DOWNLOADS_DIR}"
    "${INCOMPLETE_DIR}"
    "${STATE_DIR}"
    "${BACKUP_DIR}"
  )

  for d in "${dirs[@]}"; do
    mkdir -p "${d}"
  done

  chown -R "${TARGET_UID}:${TARGET_GID}" "${MUSIC_ROOT}" 2>/dev/null || true
  log_ok "Pastas criadas em ${MUSIC_ROOT}"
}

# -----------------------------------------------------------------------------
# Estado da instalação (para update/uninstall)
# -----------------------------------------------------------------------------
save_state() {
  mkdir -p "${STATE_DIR}"
  {
    printf 'INSTALLER_VERSION=%q\n' "${INSTALLER_VERSION}"
    printf 'INSTALLED_AT=%q\n' "$(date -Iseconds)"
    printf 'TARGET_USER=%q\n' "${TARGET_USER}"
    printf 'TARGET_UID=%q\n' "${TARGET_UID}"
    printf 'TARGET_GID=%q\n' "${TARGET_GID}"
    printf 'TARGET_HOME=%q\n' "${TARGET_HOME}"
    printf 'DISK_DEVICE=%q\n' "${DISK_DEVICE}"
    printf 'DISK_LABEL=%q\n' "${DISK_LABEL}"
    printf 'DISK_FSTYPE=%q\n' "${DISK_FSTYPE}"
    printf 'MOUNT_POINT=%q\n' "${MOUNT_POINT}"
    printf 'MUSIC_ROOT=%q\n' "${MUSIC_ROOT}"
    printf 'DOWNLOADS_DIR=%q\n' "${DOWNLOADS_DIR}"
    printf 'INCOMPLETE_DIR=%q\n' "${INCOMPLETE_DIR}"
    printf 'PLEX_LIBRARY_NAME=%q\n' "${PLEX_LIBRARY_NAME}"
    printf 'INSTALL_PLEX=%q\n' "${INSTALL_PLEX}"
    printf 'INSTALL_LIDARR=%q\n' "${INSTALL_LIDARR}"
    printf 'INSTALL_PROWLARR=%q\n' "${INSTALL_PROWLARR}"
    printf 'INSTALL_QBITTORRENT=%q\n' "${INSTALL_QBITTORRENT}"
  } > "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"
  log_ok "Estado salvo em ${STATE_FILE}"
}

load_state() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    return 1
  fi
  # shellcheck source=/dev/null
  source "${STATE_FILE}"
  if [[ -z "${TARGET_USER:-}" ]]; then
    log_warn "Estado inválido: TARGET_USER vazio"
    return 1
  fi
  QBITTORRENT_CONFIG_DIR="${TARGET_HOME}/.config/qBittorrent"
  return 0
}

# -----------------------------------------------------------------------------
# Backup simples de configs
# -----------------------------------------------------------------------------
backup_configs() {
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local dest="${BACKUP_DIR}/backup-${stamp}"
  mkdir -p "${dest}"

  [[ -d "${LIDARR_CONFIG_DIR}" ]] && cp -a "${LIDARR_CONFIG_DIR}" "${dest}/lidarr" 2>/dev/null || true
  [[ -d "${PROWLARR_CONFIG_DIR}" ]] && cp -a "${PROWLARR_CONFIG_DIR}" "${dest}/prowlarr" 2>/dev/null || true
  [[ -d "${QBITTORRENT_CONFIG_DIR}" ]] && cp -a "${QBITTORRENT_CONFIG_DIR}" "${dest}/qbittorrent" 2>/dev/null || true

  echo "${dest}"
}

# -----------------------------------------------------------------------------
# Utilitários
# -----------------------------------------------------------------------------
run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

wait_for_port() {
  local port="$1"
  local timeout="${2:-30}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

service_enable_start() {
  local unit="$1"
  systemctl daemon-reload
  systemctl enable "${unit}" >/dev/null 2>&1 || true
  systemctl restart "${unit}"
  if systemctl is-active --quiet "${unit}"; then
    log_ok "Serviço ${unit} ativo"
  else
    log_warn "Serviço ${unit} pode não ter iniciado corretamente"
    systemctl status "${unit}" --no-pager -l | head -20 || true
  fi
}

print_final_urls() {
  local ip
  ip="$(get_local_ip)"

  echo
  echo -e "${C_CYAN}====================================${C_RESET}"
  echo
  echo -e "${C_BOLD}${C_GREEN}Instalação concluída${C_RESET}"
  echo

  if [[ "${INSTALL_PLEX}" == "true" ]]; then
    echo -e "${C_BOLD}Plex${C_RESET}"
    echo -e "http://${ip}:${PORT_PLEX}/web"
    echo
  fi
  if [[ "${INSTALL_LIDARR}" == "true" ]]; then
    echo -e "${C_BOLD}Lidarr${C_RESET}"
    echo -e "http://${ip}:${PORT_LIDARR}"
    echo
  fi
  if [[ "${INSTALL_PROWLARR}" == "true" ]]; then
    echo -e "${C_BOLD}Prowlarr${C_RESET}"
    echo -e "http://${ip}:${PORT_PROWLARR}"
    echo
  fi
  if [[ "${INSTALL_QBITTORRENT}" == "true" ]]; then
    echo -e "${C_BOLD}qBittorrent${C_RESET}"
    echo -e "http://${ip}:${PORT_QBITTORRENT}"
    if [[ -f "${STATE_DIR}/qbittorrent-temp-password.txt" ]]; then
      echo -e "${C_DIM}Usuário: admin · Senha temporária: $(cat "${STATE_DIR}/qbittorrent-temp-password.txt")${C_RESET}"
    else
      echo -e "${C_DIM}Usuário: admin · Senha: ver journalctl -u qbittorrent-nox@${TARGET_USER}${C_RESET}"
    fi
    echo
  fi

  echo -e "${C_CYAN}====================================${C_RESET}"
  echo
  echo -e "${C_DIM}Biblioteca: ${MUSIC_ROOT}${C_RESET}"
  echo -e "${C_DIM}Estado:     ${STATE_FILE}${C_RESET}"
  echo
}
