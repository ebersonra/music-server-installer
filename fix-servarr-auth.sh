#!/usr/bin/env bash
# fix-servarr-auth.sh — Corrige Lidarr/Prowlarr (HTTP 500 / DryIoc IAuthorizationHandler)
#
# Causa: AuthenticationRequired=Disabled é INVÁLIDO no Servarr atual.
# Valor correto: DisabledForLocalAddresses (ou Enabled).
#
# Runtime padrão: Docker Compose (ADR-0001). Também tenta parar units systemd legado.
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

FACTORY_RESET=false
if [[ "${1:-}" == "--factory-reset" ]]; then
  FACTORY_RESET=true
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Execute: sudo ./fix-servarr-auth.sh"
  echo "         sudo msi-fix-servarr-auth"
  echo "         sudo ./fix-servarr-auth.sh --factory-reset"
  exit 1
fi

# shellcheck source=config.sh
source "${INSTALLER_ROOT}/config.sh"
# shellcheck source=services/docker.sh
source "${INSTALLER_ROOT}/services/docker.sh" 2>/dev/null || true

if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${STATE_FILE}"
fi

LIDARR_CONFIG_DIR="${LIDARR_CONFIG_DIR:-/var/lib/lidarr}"
PROWLARR_CONFIG_DIR="${PROWLARR_CONFIG_DIR:-/var/lib/prowlarr}"
[[ -f /var/lib/lidarr/config.xml ]] && LIDARR_CONFIG_DIR="/var/lib/lidarr"
[[ -f /var/lib/prowlarr/config.xml ]] && PROWLARR_CONFIG_DIR="/var/lib/prowlarr"

PUID="${TARGET_UID:-1000}"
PGID="$(getent group media 2>/dev/null | cut -d: -f3 || echo "${TARGET_GID:-1000}")"

write_clean_config() {
  local conf="$1"
  local port="$2"
  local name="$3"
  local data_dir
  data_dir="$(dirname "${conf}")"

  mkdir -p "${data_dir}"
  if [[ -f "${conf}" ]]; then
    cp -a "${conf}" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "${conf}" <<EOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>${port}</Port>
  <SslPort>$((port - 1800))</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <AuthenticationMethod>None</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Branch>master</Branch>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <InstanceName>${name}</InstanceName>
  <UpdateMechanism>BuiltIn</UpdateMechanism>
</Config>
EOF

  chown "${PUID}:${PGID}" "${conf}" 2>/dev/null || true
  chmod 640 "${conf}"
  echo "✓  ${name}: config.xml OK (None + DisabledForLocalAddresses)"
}

factory_reset_app() {
  local data_dir="$1"
  local name="$2"
  mkdir -p "${data_dir}"
  local stamp
  stamp="$(date +%Y%m%d%H%M%S)"
  if compgen -G "${data_dir}/*" > /dev/null; then
    tar -C "$(dirname "${data_dir}")" -czf "${data_dir}.bak.${stamp}.tgz" "$(basename "${data_dir}")" 2>/dev/null || true
  fi
  rm -f "${data_dir}/config.xml"
  rm -rf "${data_dir}/asp" "${data_dir}/Sentry" 2>/dev/null || true
  chown -R "${PUID}:${PGID}" "${data_dir}" 2>/dev/null || true
  echo "✓  ${name}: factory-reset aplicado"
}

_stop_servarr() {
  echo "==> Parando serviços"
  if [[ -f "${INSTALLER_ROOT}/.env" ]] && command -v docker &>/dev/null; then
    docker compose --project-directory "${INSTALLER_ROOT}" -f "${INSTALLER_ROOT}/docker-compose.yml" \
      --env-file "${INSTALLER_ROOT}/.env" stop lidarr prowlarr 2>/dev/null || true
  fi
  systemctl stop lidarr 2>/dev/null || true
  systemctl stop prowlarr 2>/dev/null || true
  sleep 1
}

_start_servarr() {
  echo "==> Reiniciando"
  if [[ -f "${INSTALLER_ROOT}/.env" ]] && command -v docker &>/dev/null; then
    docker compose --project-directory "${INSTALLER_ROOT}" -f "${INSTALLER_ROOT}/docker-compose.yml" \
      --env-file "${INSTALLER_ROOT}/.env" up -d lidarr prowlarr
  else
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart lidarr prowlarr 2>/dev/null || true
  fi
  sleep 5
}

_stop_servarr

if [[ "${FACTORY_RESET}" == "true" ]]; then
  factory_reset_app "${LIDARR_CONFIG_DIR}" Lidarr
  factory_reset_app "${PROWLARR_CONFIG_DIR}" Prowlarr
fi

write_clean_config "${LIDARR_CONFIG_DIR}/config.xml" 8686 Lidarr
write_clean_config "${PROWLARR_CONFIG_DIR}/config.xml" 9696 Prowlarr

chown -R "${PUID}:${PGID}" "${LIDARR_CONFIG_DIR}" "${PROWLARR_CONFIG_DIR}" 2>/dev/null || true

_start_servarr

echo
if command -v docker &>/dev/null; then
  echo "Status: lidarr=$(docker inspect -f '{{.State.Status}}' music-lidarr 2>/dev/null || echo n/a) / prowlarr=$(docker inspect -f '{{.State.Status}}' music-prowlarr 2>/dev/null || echo n/a)"
else
  echo "Status: $(systemctl is-active lidarr 2>/dev/null || echo n/a) / $(systemctl is-active prowlarr 2>/dev/null || echo n/a)"
fi
echo "HTTP:"
code_l="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8686/ || echo err)"
code_p="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9696/ || echo err)"
echo "  Lidarr:   HTTP ${code_l}"
echo "  Prowlarr: HTTP ${code_p}"

if [[ "${code_l}" != "200" || "${code_p}" != "200" ]]; then
  echo
  echo "⚠  Ainda sem HTTP 200. Últimos logs:"
  docker logs music-lidarr --tail 15 2>/dev/null || true
  docker logs music-prowlarr --tail 15 2>/dev/null || true
  exit 1
fi

ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
ip="${ip:-127.0.0.1}"
echo
echo "OK — abra sem login:"
echo "  http://${ip}:8686"
echo "  http://${ip}:9696"
echo
echo "Depois: Settings → General → Security → Forms → crie usuário/senha → Save"
