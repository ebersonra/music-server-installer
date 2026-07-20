#!/usr/bin/env bash
# services/firewall.sh — UFW / abertura de portas
# shellcheck disable=SC2154

configure_firewall() {
  log_step "Abrindo portas (firewall)"

  if ! command -v ufw &>/dev/null; then
    log_warn "UFW não instalado — pulando configuração de firewall"
    return 0
  fi

  # Garantir SSH antes de habilitar UFW (evitar lockout)
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true

  if [[ "${INSTALL_PLEX}" == "true" ]]; then
    ufw allow "${PORT_PLEX}/tcp" comment "Plex Media Server" >/dev/null 2>&1 || true
    # Portas extras do Plex (GDM, DLNA opcional)
    ufw allow 3005/tcp comment "Plex Companion" >/dev/null 2>&1 || true
    ufw allow 8324/tcp comment "Plex Roku" >/dev/null 2>&1 || true
    ufw allow 32469/tcp comment "Plex DLNA" >/dev/null 2>&1 || true
  fi

  if [[ "${INSTALL_LIDARR}" == "true" ]]; then
    ufw allow "${PORT_LIDARR}/tcp" comment "Lidarr" >/dev/null 2>&1 || true
  fi

  if [[ "${INSTALL_PROWLARR}" == "true" ]]; then
    ufw allow "${PORT_PROWLARR}/tcp" comment "Prowlarr" >/dev/null 2>&1 || true
  fi

  if [[ "${INSTALL_QBITTORRENT}" == "true" ]]; then
    ufw allow "${PORT_QBITTORRENT}/tcp" comment "qBittorrent WebUI" >/dev/null 2>&1 || true
    # Faixa BT padrão
    ufw allow 6881:6891/tcp comment "qBittorrent BT" >/dev/null 2>&1 || true
    ufw allow 6881:6891/udp comment "qBittorrent BT UDP" >/dev/null 2>&1 || true
  fi

  # Habilitar UFW se ainda inativo (não forçar se usuário desabilitou de propósito)
  local status
  status="$(ufw status 2>/dev/null | head -1 || true)"
  if echo "${status}" | grep -qi "inactive"; then
    log_info "Ativando UFW..."
    ufw --force enable >/dev/null 2>&1 || log_warn "Não foi possível ativar o UFW automaticamente"
  fi

  log_ok "Portas configuradas no firewall"
  ufw status numbered 2>/dev/null | head -30 || true
}

remove_firewall_rules() {
  if ! command -v ufw &>/dev/null; then
    return 0
  fi
  log_step "Removendo regras de firewall do instalador"

  for port in "${PORT_PLEX}" "${PORT_LIDARR}" "${PORT_PROWLARR}" "${PORT_QBITTORRENT}"; do
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  done
  ufw delete allow 3005/tcp >/dev/null 2>&1 || true
  ufw delete allow 8324/tcp >/dev/null 2>&1 || true
  ufw delete allow 32469/tcp >/dev/null 2>&1 || true
  ufw delete allow 6881:6891/tcp >/dev/null 2>&1 || true
  ufw delete allow 6881:6891/udp >/dev/null 2>&1 || true

  log_ok "Regras de firewall removidas (quando existiam)"
}
