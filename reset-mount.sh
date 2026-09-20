#!/usr/bin/env bash
# reset-mount.sh — Limpa mount fantasma/morto (ex.: /media/music), automount e fstab antigo
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Execute com: sudo ./reset-mount.sh"
  exit 1
fi

MOUNT_POINT="${1:-/media/music}"
UDISKS_NO_AUTOMOUNT_RULE="/etc/udev/rules.d/99-music-server-installer-no-automount.rules"

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

wait_umount() {
  local mp="$1"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! findmnt -n "${mp}" &>/dev/null; then
      return 0
    fi
    sleep 0.3
  done
  return 1
}

echo "==> Verificando ${MOUNT_POINT}"
src=""
if findmnt -n "${MOUNT_POINT}" &>/dev/null; then
  src="$(findmnt -n -o SOURCE "${MOUNT_POINT}" | awk '{print $1}')"
  echo "    montado como: ${src}"
  if is_stale "${MOUNT_POINT}"; then
    echo "    mount morto/fantasma (FUSE ENOTCONN ou device sumiu) — umount -l"
    umount -l "${MOUNT_POINT}" || umount "${MOUNT_POINT}" || true
  elif [[ ! -b "${src}" ]]; then
    echo "    mount fantasma (device inexistente) — desmontando com -l"
    umount -l "${MOUNT_POINT}" || umount "${MOUNT_POINT}" || true
  else
    echo "    desmontando..."
    umount "${MOUNT_POINT}" 2>/dev/null || umount -l "${MOUNT_POINT}" || true
  fi
  wait_umount "${MOUNT_POINT}" || echo "    aviso: findmnt ainda lista ${MOUNT_POINT}"
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

# Desmontar o mesmo device se ainda estiver em outro path (desktop)
if [[ -n "${src}" && -b "${src}" ]]; then
  echo "==> Mounts concorrentes de ${src}"
  while IFS= read -r other; do
    [[ -z "${other}" || "${other}" == "${MOUNT_POINT}" ]] && continue
    echo "    desmontando ${other}"
    umount "${other}" 2>/dev/null || umount -l "${other}" 2>/dev/null || true
  done < <(findmnt -n -o TARGET -S "${src}" 2>/dev/null || true)
  if command -v udisksctl >/dev/null 2>&1; then
    udisksctl unmount -b "${src}" 2>/dev/null || true
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
echo "==> Automount systemd (${unit})"
if systemctl cat "${unit}" &>/dev/null; then
  systemctl stop "${unit}" 2>/dev/null || true
  systemctl disable "${unit}" 2>/dev/null || true
  systemctl mask "${unit}" 2>/dev/null || true
  echo "    parado/mascarado"
else
  echo "    unidade ausente (ok)"
fi

# Garantir regra udev se soubermos o UUID do volume (estado ou blkid do device)
echo "==> Regra udev no-automount"
uuid=""
if [[ -f /var/lib/music-server-installer/install.state ]]; then
  # Estado usa printf %q — source em subshell é o parse seguro
  uuid="$(bash -c 'source /var/lib/music-server-installer/install.state; printf %s "${DISK_UUID:-}"' 2>/dev/null || true)"
fi
if [[ -z "${uuid}" && -n "${src}" && -b "${src}" ]]; then
  uuid="$(blkid -s UUID -o value "${src}" 2>/dev/null || true)"
fi
if [[ -n "${uuid}" ]]; then
  mkdir -p "$(dirname "${UDISKS_NO_AUTOMOUNT_RULE}")"
  {
    echo "# music-server-installer — impede automount do desktop (udisks) neste volume"
    if [[ -f "${UDISKS_NO_AUTOMOUNT_RULE}" ]]; then
      grep -E '^ENV\{ID_FS_UUID\}==' "${UDISKS_NO_AUTOMOUNT_RULE}" 2>/dev/null \
        | grep -vF "\"${uuid}\"" || true
    fi
    echo "ENV{ID_FS_UUID}==\"${uuid}\", ENV{UDISKS_AUTO}=\"0\", ENV{UDISKS_PRESENTATION_NOPOLICY}=\"1\""
  } > "${UDISKS_NO_AUTOMOUNT_RULE}"
  chmod 644 "${UDISKS_NO_AUTOMOUNT_RULE}"
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
  echo "    UUID=${uuid} → UDISKS_AUTO=0"
else
  echo "    UUID desconhecido — rode mount.sh depois (ele instala a regra)"
fi

echo
echo "Pronto. Remonte com:"
echo "  sudo ./mount.sh"
echo
echo "Dica: ponto de montagem real deste setup: /media/music (Musicas + Fotos)."
echo "      Se o cabo USB soltou, reconecte o HD antes de remontar."
