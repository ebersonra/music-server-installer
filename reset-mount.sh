#!/usr/bin/env bash
# reset-mount.sh — Limpa mount fantasma/morto (ex.: /media/music) e fstab antigo
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Execute com: sudo ./reset-mount.sh"
  exit 1
fi

MOUNT_POINT="${1:-/media/music}"

is_stale() {
  local mp="$1"
  local err src
  if ! findmnt -n "${mp}" &>/dev/null; then
    return 1
  fi
  err="$(stat "${mp}" 2>&1 >/dev/null || true)"
  if [[ "${err}" == *"Transport endpoint is not connected"* ]] || \
     [[ "${err}" == *"Ponto final de transporte"* ]]; then
    return 0
  fi
  src="$(findmnt -n -o SOURCE "${mp}" 2>/dev/null | awk '{print $1}')"
  if [[ -n "${src}" && ! -b "${src}" && ! -e "${src}" ]]; then
    return 0
  fi
  return 1
}

echo "==> Verificando ${MOUNT_POINT}"
if findmnt -n "${MOUNT_POINT}" &>/dev/null; then
  src="$(findmnt -n -o SOURCE "${MOUNT_POINT}" | awk '{print $1}')"
  echo "    montado como: ${src}"
  if is_stale "${MOUNT_POINT}"; then
    echo "    mount morto/fantasma (FUSE ENOTCONN ou device sumiu) — umount -l"
    umount -l "${MOUNT_POINT}" || umount "${MOUNT_POINT}"
  elif [[ ! -b "${src}" ]]; then
    echo "    mount fantasma (device inexistente) — desmontando com -l"
    umount -l "${MOUNT_POINT}" || umount "${MOUNT_POINT}"
  else
    echo "    desmontando..."
    umount "${MOUNT_POINT}" || umount -l "${MOUNT_POINT}"
  fi
  echo "    OK desmontado"
else
  # Às vezes findmnt já limpou mas o dentry FUSE ainda responde ENOTCONN
  err="$(stat "${MOUNT_POINT}" 2>&1 >/dev/null || true)"
  if [[ "${err}" == *"Transport endpoint is not connected"* ]] || \
     [[ "${err}" == *"Ponto final de transporte"* ]]; then
    echo "    dentry FUSE morto sem findmnt — umount -l"
    umount -l "${MOUNT_POINT}" 2>/dev/null || true
    echo "    OK"
  else
    echo "    já livre"
  fi
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
echo "Pronto. Remonte com:"
echo "  sudo ./mount.sh"
echo
echo "Dica: ponto de montagem real deste setup: /media/music (Musicas + Fotos)."
echo "      Se o cabo USB soltou, reconecte o HD antes de remontar."
