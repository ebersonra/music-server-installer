#!/usr/bin/env bash
# services/flaresolverr.sh — Instalação nativa do FlareSolverr (binário GitHub)
# shellcheck disable=SC2154

_flaresolverr_resolve_download_url() {
  local api_url="https://api.github.com/repos/FlareSolverr/FlareSolverr/releases/latest"
  local download_url=""

  download_url="$(curl -fsSL "${api_url}" 2>/dev/null \
    | jq -r '[.assets[]? | select(.name | test("linux_x64") and endswith(".tar.gz")) | .browser_download_url][0] // empty' \
    2>/dev/null || true)"

  if [[ -z "${download_url}" || "${download_url}" == "null" ]]; then
    download_url="https://github.com/FlareSolverr/FlareSolverr/releases/latest/download/flaresolverr_linux_x64.tar.gz"
  fi

  printf '%s\n' "${download_url}"
}

_ensure_flaresolverr_user() {
  if ! id flaresolverr &>/dev/null; then
    useradd --system --user-group --home-dir "${FLARESOLVERR_CONFIG_DIR}" \
      --create-home --shell /usr/sbin/nologin flaresolverr
  fi
  mkdir -p "${FLARESOLVERR_CONFIG_DIR}"
  chown -R flaresolverr:flaresolverr "${FLARESOLVERR_CONFIG_DIR}"
}

# Chromium embutido no binário precisa de Xvfb + libs do sistema
_install_flaresolverr_deps() {
  log_info "Instalando dependências do FlareSolverr (xvfb + libs Chromium)"
  export DEBIAN_FRONTEND=noninteractive
  local pkgs=(
    xvfb
    fonts-liberation
    libnss3
    libatk1.0-0
    libatk-bridge2.0-0
    libcups2
    libdrm2
    libxkbcommon0
    libxcomposite1
    libxdamage1
    libxfixes3
    libxrandr2
    libgbm1
    libasound2t64
    libpango-1.0-0
    libcairo2
    libx11-6
    libx11-xcb1
    libxcb1
    libxext6
  )
  # libasound2t64 (Ubuntu 24.04+) ou libasound2 (mais antigo)
  if ! apt-cache show libasound2t64 &>/dev/null; then
    pkgs=( "${pkgs[@]/libasound2t64}" )
    pkgs+=( libasound2 )
  fi
  apt-get install -y -qq "${pkgs[@]}" || {
    # Fallback mínimo se alguns nomes de pacote diferirem
    apt-get install -y -qq xvfb fonts-liberation libnss3 libatk1.0-0 \
      libxcomposite1 libxdamage1 libxrandr2 libgbm1 libx11-6 || true
    apt-get install -y -qq xvfb || {
      log_error "Falha ao instalar xvfb (obrigatório para FlareSolverr headless)"
      return 1
    }
  }
  if ! command -v Xvfb &>/dev/null; then
    log_error "Xvfb não encontrado após apt install"
    return 1
  fi
  log_ok "Dependências FlareSolverr OK (Xvfb presente)"
}

_install_flaresolverr_unit() {
  local unit_src="${INSTALLER_ROOT}/templates/systemd/flaresolverr.service"
  local unit_dst="/etc/systemd/system/flaresolverr.service"
  local host="${FLARESOLVERR_HOST:-127.0.0.1}"
  local port="${PORT_FLARESOLVERR:-8191}"
  local dir="${FLARESOLVERR_DIR:-/opt/flaresolverr}"

  if [[ -f "${unit_src}" ]]; then
    sed -e "s|@HOST@|${host}|g" \
        -e "s|@PORT@|${port}|g" \
        -e "s|@DIR@|${dir}|g" \
        "${unit_src}" > "${unit_dst}"
  else
    cat > "${unit_dst}" <<EOF
[Unit]
Description=FlareSolverr
After=network.target

[Service]
Type=simple
User=flaresolverr
Group=flaresolverr
Restart=always
RestartSec=5
Environment=LOG_LEVEL=info
Environment=CAPTCHA_SOLVER=none
Environment=HOST=${host}
Environment=PORT=${port}
WorkingDirectory=${dir}
ExecStart=${dir}/flaresolverr
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  fi
}

install_flaresolverr() {
  log_step "Instalando FlareSolverr"

  case "${OS_ARCH:-$(uname -m)}" in
    amd64|x86_64) ;;
    *)
      log_error "FlareSolverr binário oficial só tem linux_x64 (arch: ${OS_ARCH:-unknown})"
      return 1
      ;;
  esac

  _install_flaresolverr_deps || return 1

  local download_url
  download_url="$(_flaresolverr_resolve_download_url)"
  log_info "Baixando FlareSolverr..."

  local tmpdir
  tmpdir="$(mktemp -d)"
  if ! curl -fL --retry 3 --retry-delay 2 -o "${tmpdir}/flaresolverr.tar.gz" "${download_url}"; then
    log_error "Falha no download do FlareSolverr"
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! tar -xzf "${tmpdir}/flaresolverr.tar.gz" -C "${tmpdir}"; then
    log_error "Arquivo FlareSolverr inválido (tar)"
    rm -rf "${tmpdir}"
    return 1
  fi

  local extracted=""
  if [[ -x "${tmpdir}/flaresolverr/flaresolverr" ]]; then
    extracted="${tmpdir}/flaresolverr"
  elif [[ -x "${tmpdir}/flaresolverr" ]]; then
    mkdir -p "${tmpdir}/pkg"
    mv "${tmpdir}/flaresolverr" "${tmpdir}/pkg/"
    # tarball às vezes solta binário + libs na raiz
    find "${tmpdir}" -maxdepth 1 -mindepth 1 ! -name pkg ! -name '*.tar.gz' -exec mv {} "${tmpdir}/pkg/" \;
    extracted="${tmpdir}/pkg"
  else
    extracted="$(find "${tmpdir}" -type f -name flaresolverr -executable 2>/dev/null | head -1)"
    if [[ -n "${extracted}" ]]; then
      extracted="$(dirname "${extracted}")"
    fi
  fi

  if [[ -z "${extracted}" || ! -x "${extracted}/flaresolverr" ]]; then
    log_error "Binário flaresolverr não encontrado no tarball"
    rm -rf "${tmpdir}"
    return 1
  fi

  _ensure_flaresolverr_user

  systemctl stop flaresolverr 2>/dev/null || true
  rm -rf "${FLARESOLVERR_DIR}"
  mkdir -p "$(dirname "${FLARESOLVERR_DIR}")"
  mv "${extracted}" "${FLARESOLVERR_DIR}"
  chown -R flaresolverr:flaresolverr "${FLARESOLVERR_DIR}"
  rm -rf "${tmpdir}"

  _install_flaresolverr_unit
  service_enable_start flaresolverr

  if wait_for_port "${PORT_FLARESOLVERR}" 45; then
    log_ok "FlareSolverr ativo em ${FLARESOLVERR_HOST}:${PORT_FLARESOLVERR}"
  else
    log_warn "FlareSolverr pode não estar escutando ainda — verifique: systemctl status flaresolverr"
  fi

  log_ok "FlareSolverr instalado"
}

update_flaresolverr() {
  log_step "Atualizando FlareSolverr"
  install_flaresolverr
}

uninstall_flaresolverr() {
  log_step "Removendo FlareSolverr"
  systemctl stop flaresolverr 2>/dev/null || true
  systemctl disable flaresolverr 2>/dev/null || true
  rm -f /etc/systemd/system/flaresolverr.service
  systemctl daemon-reload
  rm -rf "${FLARESOLVERR_DIR:-/opt/flaresolverr}"
  log_warn "Usuário/dados em ${FLARESOLVERR_CONFIG_DIR:-/var/lib/flaresolverr} preservados (use --purge-data no uninstall)."
  log_ok "FlareSolverr removido"
}
