#!/usr/bin/env bash
# services/lidarr.sh — Instalação e configuração do Lidarr
# shellcheck disable=SC2154

_install_servarr_repo() {
  if [[ -f /etc/apt/sources.list.d/servarr.list ]]; then
    return 0
  fi

  # Chave do repositório Servarr (Lidarr/Prowlarr/Radarr)
  curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2009837CBFFD68F45FBED23B7F631A8B8F0E6E2E" \
    | gpg --dearmor -o /usr/share/keyrings/servarr-archive-keyring.gpg

  local codename
  codename="${OS_CODENAME:-}"
  if [[ -z "${codename}" ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    codename="${VERSION_CODENAME:-stable}"
  fi

  # Servarr usa suite genérica; fallback para debian-stable
  echo "deb [signed-by=/usr/share/keyrings/servarr-archive-keyring.gpg] https://apt.servarr.com/debian ${codename} main" \
    > /etc/apt/sources.list.d/servarr.list

  if ! apt-get update -qq 2>/dev/null; then
    log_warn "Suite ${codename} falhou no apt.servarr.com — tentando 'jammy'"
    echo "deb [signed-by=/usr/share/keyrings/servarr-archive-keyring.gpg] https://apt.servarr.com/debian jammy main" \
      > /etc/apt/sources.list.d/servarr.list
    apt-get update -qq || die "Falha ao atualizar repositório Servarr"
  fi
}

_install_lidarr_from_github() {
  log_info "Instalando Lidarr via release GitHub (fallback)"
  local arch="amd64"
  case "${OS_ARCH}" in
    amd64|x86_64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    armhf|armv7*) arch="arm" ;;
    *) die "Arquitetura não suportada para Lidarr: ${OS_ARCH}" ;;
  esac

  local api_url="https://api.github.com/repos/Lidarr/Lidarr/releases/latest"
  local download_url
  download_url="$(curl -fsSL "${api_url}" \
    | jq -r --arg arch "linux-core-${arch}" \
      '[.assets[] | select(.name | test($arch) and endswith(".tar.gz")) | .browser_download_url][0] // empty')"

  if [[ -z "${download_url}" || "${download_url}" == "null" ]]; then
    die "Não foi possível obter URL de download do Lidarr"
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  curl -fsSL -o "${tmpdir}/lidarr.tar.gz" "${download_url}"
  tar -xzf "${tmpdir}/lidarr.tar.gz" -C "${tmpdir}"

  rm -rf /opt/Lidarr
  mv "${tmpdir}"/Lidarr /opt/Lidarr
  rm -rf "${tmpdir}"

  # Usuário de sistema
  if ! id lidarr &>/dev/null; then
    useradd --system --user-group --home-dir "${LIDARR_CONFIG_DIR}" --create-home --shell /usr/sbin/nologin lidarr
  fi
  mkdir -p "${LIDARR_CONFIG_DIR}"
  chown -R lidarr:lidarr /opt/Lidarr "${LIDARR_CONFIG_DIR}"

  # Unit systemd a partir do template
  local unit_src="${INSTALLER_ROOT}/templates/systemd/lidarr.service"
  local unit_dst="/etc/systemd/system/lidarr.service"
  if [[ -f "${unit_src}" ]]; then
    sed -e "s|@USER@|lidarr|g" \
        -e "s|@CONFIG@|${LIDARR_CONFIG_DIR}|g" \
        "${unit_src}" > "${unit_dst}"
  else
    cat > "${unit_dst}" <<EOF
[Unit]
Description=Lidarr Daemon
After=network.target

[Service]
User=lidarr
Group=lidarr
Type=simple
ExecStart=/opt/Lidarr/Lidarr -nobrowser -data=${LIDARR_CONFIG_DIR}
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  fi
}

_apply_lidarr_config() {
  mkdir -p "${LIDARR_CONFIG_DIR}"
  local conf="${LIDARR_CONFIG_DIR}/config.xml"
  local template="${INSTALLER_ROOT}/templates/lidarr.xml"

  # Só aplica template se ainda não houver config (não sobrescrever instalação existente)
  if [[ ! -f "${conf}" ]]; then
    if [[ -f "${template}" ]]; then
      sed -e "s|__PORT__|${PORT_LIDARR}|g" \
          -e "s|__MUSIC_ROOT__|${MUSIC_ROOT}|g" \
          -e "s|__DOWNLOADS_DIR__|${DOWNLOADS_DIR}|g" \
          "${template}" > "${conf}"
    else
      cat > "${conf}" <<EOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>${PORT_LIDARR}</Port>
  <SslPort>6868</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <AuthenticationMethod>Forms</AuthenticationMethod>
  <AuthenticationRequired>Enabled</AuthenticationRequired>
  <Branch>master</Branch>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <UpdateMechanism>BuiltIn</UpdateMechanism>
</Config>
EOF
    fi
    chown lidarr:lidarr "${conf}" 2>/dev/null || true
    chmod 640 "${conf}"
  fi

  # Root folders hint
  mkdir -p "${MUSIC_ROOT}/Artistas"
  chown -R "${TARGET_UID}:${TARGET_GID}" "${MUSIC_ROOT}" 2>/dev/null || true
  if id lidarr &>/dev/null; then
    usermod -aG media lidarr 2>/dev/null || true
    # Acesso de escrita
    setfacl -m u:lidarr:rwX "${MUSIC_ROOT}" 2>/dev/null || true
    setfacl -R -m u:lidarr:rwX "${MUSIC_ROOT}" 2>/dev/null || true
  fi
}

install_lidarr() {
  log_step "Instalando Lidarr"
  export DEBIAN_FRONTEND=noninteractive

  local installed=false

  # Tentativa 1: pacote apt Servarr
  _install_servarr_repo || true
  if apt-cache show lidarr &>/dev/null; then
    if apt-get install -y -qq lidarr; then
      installed=true
    fi
  fi

  # Tentativa 2: GitHub release
  if [[ "${installed}" != "true" ]]; then
    _install_lidarr_from_github
    installed=true
  fi

  _apply_lidarr_config
  service_enable_start lidarr
  log_ok "Lidarr instalado na porta ${PORT_LIDARR}"
}

update_lidarr() {
  log_step "Atualizando Lidarr"
  export DEBIAN_FRONTEND=noninteractive
  if dpkg -l lidarr &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq --only-upgrade lidarr || log_warn "Sem atualização apt do Lidarr"
  else
    # Reinstalar via GitHub (nova release)
    systemctl stop lidarr 2>/dev/null || true
    _install_lidarr_from_github
  fi
  systemctl restart lidarr 2>/dev/null || true
  log_ok "Lidarr atualizado"
}

uninstall_lidarr() {
  log_step "Removendo Lidarr"
  systemctl stop lidarr 2>/dev/null || true
  systemctl disable lidarr 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y -qq lidarr 2>/dev/null || true
  apt-get purge -y -qq lidarr 2>/dev/null || true
  rm -f /etc/systemd/system/lidarr.service
  rm -rf /opt/Lidarr
  systemctl daemon-reload
  log_warn "Dados em ${LIDARR_CONFIG_DIR} preservados. Remova manualmente se desejar."
  log_ok "Lidarr removido"
}
