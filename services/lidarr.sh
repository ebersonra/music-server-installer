#!/usr/bin/env bash
# services/lidarr.sh — Instalação e configuração do Lidarr
# shellcheck disable=SC2154

_servarr_arch() {
  case "${OS_ARCH}" in
    amd64|x86_64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    armhf|armv7*) echo "arm" ;;
    *) echo "" ;;
  esac
}

_install_servarr_repo() {
  if [[ -f /etc/apt/sources.list.d/servarr.list ]]; then
    return 0
  fi

  local key_url="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2009837CBFFD68F45FBED23B7F631A8B8F0E6E2E"
  local tmpkey
  tmpkey="$(mktemp)"
  if ! curl -fsSL "${key_url}" -o "${tmpkey}" || ! grep -q "BEGIN PGP PUBLIC KEY" "${tmpkey}"; then
    log_warn "Chave GPG do Servarr indisponível — pulando repositório APT"
    rm -f "${tmpkey}"
    return 1
  fi
  gpg --dearmor -o /usr/share/keyrings/servarr-archive-keyring.gpg < "${tmpkey}"
  rm -f "${tmpkey}"

  local codename
  codename="${OS_CODENAME:-}"
  if [[ -z "${codename}" ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    codename="${VERSION_CODENAME:-jammy}"
  fi

  echo "deb [signed-by=/usr/share/keyrings/servarr-archive-keyring.gpg] https://apt.servarr.com/debian ${codename} main" \
    > /etc/apt/sources.list.d/servarr.list

  if ! apt-get update -qq 2>/dev/null; then
    log_warn "Suite ${codename} falhou no apt.servarr.com — tentando 'jammy'"
    echo "deb [signed-by=/usr/share/keyrings/servarr-archive-keyring.gpg] https://apt.servarr.com/debian jammy main" \
      > /etc/apt/sources.list.d/servarr.list
    if ! apt-get update -qq 2>/dev/null; then
      log_warn "Repositório Servarr APT indisponível"
      rm -f /etc/apt/sources.list.d/servarr.list
      return 1
    fi
  fi
}

_lidarr_resolve_download_url() {
  local arch="$1"
  local api_url="https://api.github.com/repos/Lidarr/Lidarr/releases/latest"
  local download_url=""

  # Assets usam linux-core-x64 (não amd64)
  download_url="$(curl -fsSL "${api_url}" 2>/dev/null \
    | jq -r --arg arch "linux-core-${arch}" \
      '[.assets[]? | select(.name | test($arch) and endswith(".tar.gz")) | .browser_download_url][0] // empty' \
    2>/dev/null || true)"

  if [[ -z "${download_url}" || "${download_url}" == "null" ]]; then
    download_url="https://lidarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=${arch}"
  fi

  printf '%s\n' "${download_url}"
}

_install_lidarr_from_github() {
  log_info "Instalando Lidarr via release GitHub (fallback)"
  local arch
  arch="$(_servarr_arch)"
  if [[ -z "${arch}" ]]; then
    log_error "Arquitetura não suportada para Lidarr: ${OS_ARCH}"
    return 1
  fi

  local download_url
  download_url="$(_lidarr_resolve_download_url "${arch}")"
  if [[ -z "${download_url}" ]]; then
    log_error "Não foi possível obter URL de download do Lidarr"
    return 1
  fi

  log_info "Baixando Lidarr (${arch})..."
  local tmpdir
  tmpdir="$(mktemp -d)"
  if ! curl -fL --retry 3 --retry-delay 2 -o "${tmpdir}/lidarr.tar.gz" "${download_url}"; then
    log_error "Falha no download do Lidarr"
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! tar -xzf "${tmpdir}/lidarr.tar.gz" -C "${tmpdir}"; then
    log_error "Arquivo Lidarr inválido (tar)"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ ! -d "${tmpdir}/Lidarr" ]]; then
    log_error "Tarball do Lidarr sem diretório Lidarr/"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf /opt/Lidarr
  mv "${tmpdir}/Lidarr" /opt/Lidarr
  rm -rf "${tmpdir}"

  if ! id lidarr &>/dev/null; then
    useradd --system --user-group --home-dir "${LIDARR_CONFIG_DIR}" --create-home --shell /usr/sbin/nologin lidarr
  fi
  mkdir -p "${LIDARR_CONFIG_DIR}"
  chown -R lidarr:lidarr /opt/Lidarr "${LIDARR_CONFIG_DIR}"

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
  return 0
}

_apply_lidarr_config() {
  mkdir -p "${LIDARR_CONFIG_DIR}"
  local conf="${LIDARR_CONFIG_DIR}/config.xml"
  local template="${INSTALLER_ROOT}/templates/lidarr.xml"

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
  <AuthenticationMethod>None</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
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

  mkdir -p "${MUSIC_ROOT}/Artistas"
  chown -R "${TARGET_UID}:${TARGET_GID}" "${MUSIC_ROOT}" 2>/dev/null || true
  if id lidarr &>/dev/null; then
    usermod -aG media lidarr 2>/dev/null || true
    [[ -n "${TARGET_USER:-}" ]] && usermod -aG "${TARGET_USER}" lidarr 2>/dev/null || true
    setfacl -m u:lidarr:rwX "${MUSIC_ROOT}" 2>/dev/null || true
    setfacl -R -m u:lidarr:rwX "${MUSIC_ROOT}" 2>/dev/null || true
  fi
}

install_lidarr() {
  log_step "Instalando Lidarr"
  export DEBIAN_FRONTEND=noninteractive

  local installed=false

  _install_servarr_repo || true
  if apt-cache show lidarr &>/dev/null; then
    if apt-get install -y -qq lidarr; then
      installed=true
    fi
  fi

  if [[ "${installed}" != "true" ]]; then
    if ! _install_lidarr_from_github; then
      return 1
    fi
    installed=true
  fi

  _apply_lidarr_config
  service_enable_start lidarr
  wait_for_port "${PORT_LIDARR}" 45 || log_warn "Lidarr ainda não escuta na porta ${PORT_LIDARR}"
  log_ok "Lidarr instalado na porta ${PORT_LIDARR}"
}

update_lidarr() {
  log_step "Atualizando Lidarr"
  export DEBIAN_FRONTEND=noninteractive
  if dpkg -l lidarr &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq --only-upgrade lidarr || log_warn "Sem atualização apt do Lidarr"
  else
    systemctl stop lidarr 2>/dev/null || true
    _install_lidarr_from_github || return 1
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
