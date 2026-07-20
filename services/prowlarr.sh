#!/usr/bin/env bash
# services/prowlarr.sh — Instalação e configuração do Prowlarr
# shellcheck disable=SC2154

_install_prowlarr_from_github() {
  log_info "Instalando Prowlarr via release GitHub (fallback)"
  local arch
  if declare -f _servarr_arch >/dev/null; then
    arch="$(_servarr_arch)"
  else
    case "${OS_ARCH}" in
      amd64|x86_64) arch="x64" ;;
      arm64|aarch64) arch="arm64" ;;
      armhf|armv7*) arch="arm" ;;
      *) arch="" ;;
    esac
  fi
  if [[ -z "${arch}" ]]; then
    log_error "Arquitetura não suportada para Prowlarr: ${OS_ARCH}"
    return 1
  fi

  local api_url="https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest"
  local download_url
  # Assets usam linux-core-x64 (não amd64)
  download_url="$(curl -fsSL "${api_url}" 2>/dev/null \
    | jq -r --arg arch "linux-core-${arch}" \
      '[.assets[]? | select(.name | test($arch) and endswith(".tar.gz")) | .browser_download_url][0] // empty' \
    2>/dev/null || true)"

  if [[ -z "${download_url}" || "${download_url}" == "null" ]]; then
    download_url="https://prowlarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=${arch}"
  fi

  log_info "Baixando Prowlarr (${arch})..."
  local tmpdir
  tmpdir="$(mktemp -d)"
  if ! curl -fL --retry 3 --retry-delay 2 -o "${tmpdir}/prowlarr.tar.gz" "${download_url}"; then
    log_error "Falha no download do Prowlarr"
    rm -rf "${tmpdir}"
    return 1
  fi
  if ! tar -xzf "${tmpdir}/prowlarr.tar.gz" -C "${tmpdir}"; then
    log_error "Arquivo Prowlarr inválido (tar)"
    rm -rf "${tmpdir}"
    return 1
  fi
  if [[ ! -d "${tmpdir}/Prowlarr" ]]; then
    log_error "Tarball do Prowlarr sem diretório Prowlarr/"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf /opt/Prowlarr
  mv "${tmpdir}/Prowlarr" /opt/Prowlarr
  rm -rf "${tmpdir}"

  if ! id prowlarr &>/dev/null; then
    useradd --system --user-group --home-dir "${PROWLARR_CONFIG_DIR}" --create-home --shell /usr/sbin/nologin prowlarr
  fi
  mkdir -p "${PROWLARR_CONFIG_DIR}"
  chown -R prowlarr:prowlarr /opt/Prowlarr "${PROWLARR_CONFIG_DIR}"

  local unit_src="${INSTALLER_ROOT}/templates/systemd/prowlarr.service"
  local unit_dst="/etc/systemd/system/prowlarr.service"
  if [[ -f "${unit_src}" ]]; then
    sed -e "s|@USER@|prowlarr|g" \
        -e "s|@CONFIG@|${PROWLARR_CONFIG_DIR}|g" \
        "${unit_src}" > "${unit_dst}"
  else
    cat > "${unit_dst}" <<EOF
[Unit]
Description=Prowlarr Daemon
After=network.target

[Service]
User=prowlarr
Group=prowlarr
Type=simple
ExecStart=/opt/Prowlarr/Prowlarr -nobrowser -data=${PROWLARR_CONFIG_DIR}
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  fi
}

_apply_prowlarr_config() {
  mkdir -p "${PROWLARR_CONFIG_DIR}"
  local conf="${PROWLARR_CONFIG_DIR}/config.xml"

  if [[ ! -f "${conf}" ]]; then
    cat > "${conf}" <<EOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>${PORT_PROWLARR}</Port>
  <SslPort>6969</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <AuthenticationMethod>None</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Branch>master</Branch>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <UpdateMechanism>BuiltIn</UpdateMechanism>
</Config>
EOF
    chown prowlarr:prowlarr "${conf}" 2>/dev/null || true
    chmod 640 "${conf}"
  fi

  if id prowlarr &>/dev/null; then
    usermod -aG media prowlarr 2>/dev/null || true
    [[ -n "${TARGET_USER:-}" ]] && usermod -aG "${TARGET_USER}" prowlarr 2>/dev/null || true
  fi
}

install_prowlarr() {
  log_step "Instalando Prowlarr"
  export DEBIAN_FRONTEND=noninteractive

  local installed=false

  if declare -f _install_servarr_repo >/dev/null; then
    _install_servarr_repo || true
  fi

  if apt-cache show prowlarr &>/dev/null; then
    if apt-get install -y -qq prowlarr; then
      installed=true
    fi
  fi

  if [[ "${installed}" != "true" ]]; then
    if ! _install_prowlarr_from_github; then
      return 1
    fi
  fi

  _apply_prowlarr_config
  service_enable_start prowlarr
  wait_for_port "${PORT_PROWLARR}" 45 || log_warn "Prowlarr ainda não escuta na porta ${PORT_PROWLARR}"
  log_ok "Prowlarr instalado na porta ${PORT_PROWLARR}"
}

update_prowlarr() {
  log_step "Atualizando Prowlarr"
  export DEBIAN_FRONTEND=noninteractive
  if dpkg -l prowlarr &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq --only-upgrade prowlarr || log_warn "Sem atualização apt do Prowlarr"
  else
    systemctl stop prowlarr 2>/dev/null || true
    _install_prowlarr_from_github
  fi
  systemctl restart prowlarr 2>/dev/null || true
  log_ok "Prowlarr atualizado"
}

uninstall_prowlarr() {
  log_step "Removendo Prowlarr"
  systemctl stop prowlarr 2>/dev/null || true
  systemctl disable prowlarr 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y -qq prowlarr 2>/dev/null || true
  apt-get purge -y -qq prowlarr 2>/dev/null || true
  rm -f /etc/systemd/system/prowlarr.service
  rm -rf /opt/Prowlarr
  systemctl daemon-reload
  log_warn "Dados em ${PROWLARR_CONFIG_DIR} preservados. Remova manualmente se desejar."
  log_ok "Prowlarr removido"
}
