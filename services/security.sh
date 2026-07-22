#!/usr/bin/env bash
# services/security.sh — Fail2Ban, unattended-upgrades e helpers de segurança
# shellcheck disable=SC2154

install_fail2ban() {
  log_step "Instalando Fail2Ban (SSH)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq fail2ban

  mkdir -p /etc/fail2ban/jail.d
  local jail_src="${INSTALLER_ROOT}/templates/fail2ban-sshd.local"
  local jail_dst="/etc/fail2ban/jail.d/sshd-music-server.local"

  if [[ -f "${jail_src}" ]]; then
    cp "${jail_src}" "${jail_dst}"
  else
    cat > "${jail_dst}" <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  fi

  # Garantir que UFW (se ativo) não conflita — Fail2Ban usa iptables/nft por padrão
  systemctl enable --now fail2ban
  systemctl restart fail2ban

  if systemctl is-active --quiet fail2ban; then
    log_ok "Fail2Ban ativo — jail sshd"
    fail2ban-client status sshd 2>/dev/null | head -20 || true
  else
    log_warn "Fail2Ban instalado, mas o serviço não está ativo"
    systemctl status fail2ban --no-pager -l | head -20 || true
  fi
}

install_unattended_upgrades() {
  log_step "Configurando atualizações automáticas de segurança"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq unattended-upgrades apt-listchanges

  # Ativar periodicidade
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

  # Preferir só security; permitir updates de segurança do Ubuntu/Debian
  local conf="/etc/apt/apt.conf.d/51music-server-unattended"
  cat > "${conf}" <<'EOF'
// Music Server Installer — só patches de segurança por padrão
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
EOF

  systemctl enable --now unattended-upgrades 2>/dev/null || true
  # Ubuntu também usa apt-daily.timer / apt-daily-upgrade.timer
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

  if unattended-upgrade --dry-run 2>/dev/null | head -5 >/dev/null; then
    log_ok "unattended-upgrades configurado (dry-run ok)"
  else
    log_ok "unattended-upgrades instalado — verifique: sudo unattended-upgrade --dry-run"
  fi

  log_info "Reboot automático desligado. Após kernel update, reinicie quando puder."
}

uninstall_fail2ban() {
  systemctl stop fail2ban 2>/dev/null || true
  systemctl disable fail2ban 2>/dev/null || true
  rm -f /etc/fail2ban/jail.d/sshd-music-server.local
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y -qq fail2ban 2>/dev/null || true
  log_ok "Fail2Ban removido"
}
