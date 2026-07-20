#!/usr/bin/env bash
# fix-servarr-auth.sh — Corrige Lidarr/Prowlarr (HTTP 500 / DryIoc IAuthorizationHandler)
#
# Causa: AuthenticationRequired=Disabled é INVÁLIDO no Servarr atual.
# Valor correto: DisabledForLocalAddresses (ou Enabled).
set -euo pipefail

FACTORY_RESET=false
if [[ "${1:-}" == "--factory-reset" ]]; then
  FACTORY_RESET=true
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Execute: sudo ./fix-servarr-auth.sh"
  echo "         sudo ./fix-servarr-auth.sh --factory-reset"
  exit 1
fi

write_clean_config() {
  local conf="$1"
  local owner="$2"
  local port="$3"
  local name="$4"
  local data_dir
  data_dir="$(dirname "${conf}")"

  mkdir -p "${data_dir}"
  if [[ -f "${conf}" ]]; then
    cp -a "${conf}" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  # AuthenticationRequiredType válidos: Enabled | DisabledForLocalAddresses
  # AuthenticationType válidos: None | Forms | External
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

  chown "${owner}:${owner}" "${conf}"
  chmod 640 "${conf}"
  echo "✓  ${name}: config.xml OK (None + DisabledForLocalAddresses)"
}

factory_reset_app() {
  local data_dir="$1"
  local owner="$2"
  local name="$3"
  mkdir -p "${data_dir}"
  local stamp
  stamp="$(date +%Y%m%d%H%M%S)"
  if compgen -G "${data_dir}/*" > /dev/null; then
    tar -C "$(dirname "${data_dir}")" -czf "${data_dir}.bak.${stamp}.tgz" "$(basename "${data_dir}")" 2>/dev/null || true
  fi
  rm -f "${data_dir}/config.xml"
  rm -rf "${data_dir}/asp" "${data_dir}/Sentry" 2>/dev/null || true
  chown -R "${owner}:${owner}" "${data_dir}"
  echo "✓  ${name}: factory-reset aplicado"
}

echo "==> Parando serviços"
systemctl stop lidarr 2>/dev/null || true
systemctl stop prowlarr 2>/dev/null || true
sleep 1

id lidarr &>/dev/null || useradd --system --user-group --home-dir /var/lib/lidarr --create-home --shell /usr/sbin/nologin lidarr
id prowlarr &>/dev/null || useradd --system --user-group --home-dir /var/lib/prowlarr --create-home --shell /usr/sbin/nologin prowlarr

if [[ "${FACTORY_RESET}" == "true" ]]; then
  factory_reset_app /var/lib/lidarr lidarr Lidarr
  factory_reset_app /var/lib/prowlarr prowlarr Prowlarr
fi

write_clean_config /var/lib/lidarr/config.xml lidarr 8686 Lidarr
write_clean_config /var/lib/prowlarr/config.xml prowlarr 9696 Prowlarr

chown -R lidarr:lidarr /var/lib/lidarr
chown -R prowlarr:prowlarr /var/lib/prowlarr

systemctl daemon-reload
echo "==> Reiniciando"
systemctl restart lidarr prowlarr
sleep 5

echo
echo "Status: $(systemctl is-active lidarr) / $(systemctl is-active prowlarr)"
echo "HTTP:"
code_l="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8686/ || echo err)"
code_p="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9696/ || echo err)"
echo "  Lidarr:   HTTP ${code_l}"
echo "  Prowlarr: HTTP ${code_p}"

if [[ "${code_l}" != "200" || "${code_p}" != "200" ]]; then
  echo
  echo "⚠  Ainda sem HTTP 200. Últimos erros:"
  journalctl -u lidarr -n 15 --no-pager 2>/dev/null | grep -iE 'Requested value|ArgumentException|Fatal|listening' || true
  journalctl -u prowlarr -n 15 --no-pager 2>/dev/null | grep -iE 'Requested value|ArgumentException|Fatal|listening' || true
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
