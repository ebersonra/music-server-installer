#!/usr/bin/env bash
# reset-mount.sh — Limpa mount fantasma /media/music e fstab antigo do HD SAMSUNG
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Execute com: sudo ./reset-mount.sh"
  exit 1
fi

MOUNT_POINT="${1:-/media/music}"

echo "==> Verificando ${MOUNT_POINT}"
if findmnt -n "${MOUNT_POINT}" &>/dev/null; then
  src="$(findmnt -n -o SOURCE "${MOUNT_POINT}" | awk '{print $1}')"
  echo "    montado como: ${src}"
  if [[ ! -b "${src}" ]]; then
    echo "    mount fantasma (device inexistente) — desmontando com -l"
    umount -l "${MOUNT_POINT}" || umount "${MOUNT_POINT}"
  else
    echo "    desmontando..."
    umount "${MOUNT_POINT}" || umount -l "${MOUNT_POINT}"
  fi
  echo "    OK desmontado"
else
  echo "    já livre"
fi

echo "==> Comentando entradas ativas de ${MOUNT_POINT} no fstab"
if grep -qE "^[^#].*[[:space:]]${MOUNT_POINT}[[:space:]]" /etc/fstab 2>/dev/null; then
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  # shellcheck disable=SC2016
  sed -i -E "s|^([^#].*[[:space:]]${MOUNT_POINT}[[:space:]].*)$|# resetado por music-server-installer\n#\1|" /etc/fstab
  echo "    fstab atualizado (backup criado)"
  grep -nE "${MOUNT_POINT}|00D61938" /etc/fstab || true
else
  echo "    nenhuma linha ativa"
fi

systemctl daemon-reload 2>/dev/null || true
unit="media-${MOUNT_POINT##*/}.automount"
systemctl stop "${unit}" 2>/dev/null || true
systemctl disable "${unit}" 2>/dev/null || true

echo
echo "Pronto. Rode de novo:"
echo "  sudo ./install.sh"
echo
echo "Dica: ponto de montagem real deste setup: /media/music (Musicas + Fotos)."
echo "      /media/* é gerenciado pelo desktop e o instalador não grava fstab nele."
