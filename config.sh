#!/usr/bin/env bash
# config.sh — Variáveis e defaults do Music Server Installer
# shellcheck disable=SC2034

# Versão do instalador
INSTALLER_VERSION="1.0.0"
INSTALLER_NAME="Music Server Installer"

# Diretório base do projeto (definido por quem faz source)
: "${INSTALLER_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Arquivo de estado da instalação (para update/uninstall)
STATE_DIR="/var/lib/music-server-installer"
STATE_FILE="${STATE_DIR}/install.state"
BACKUP_DIR="${STATE_DIR}/backups"

# Sistema suportado
SUPPORTED_DISTROS=("ubuntu" "debian")
MIN_UBUNTU_VERSION="20.04"
MIN_DEBIAN_VERSION="11"

# Usuário alvo (preenchido na detecção interativa)
TARGET_USER=""
TARGET_UID=""
TARGET_GID=""
TARGET_HOME=""

# Disco / montagem
DISK_DEVICE=""
DISK_LABEL=""
DISK_FSTYPE=""
DISK_SIZE=""
MOUNT_POINT="/media/music"
MUSIC_ROOT=""
DOWNLOADS_DIR=""
INCOMPLETE_DIR=""
PHOTOS_ROOT=""

# Bibliotecas Plex
PLEX_LIBRARY_NAME="Músicas"
PLEX_PHOTOS_LIBRARY_NAME="Fotos"

# Serviços selecionados (true/false)
INSTALL_PLEX=true
INSTALL_LIDARR=true
INSTALL_PROWLARR=true
INSTALL_QBITTORRENT=true

# Portas
PORT_PLEX=32400
PORT_LIDARR=8686
PORT_PROWLARR=9696
PORT_QBITTORRENT=8080

# URLs / repositórios
PLEX_DEB_URL="https://downloads.plex.tv/plex-media-server-new/1.41.3.9314-a0bfb8340/debian/plexmediaserver_1.41.3.9314-a0bfb8340_amd64.deb"
# Lidarr / Prowlarr via repositório oficial Servarr
SERVARR_KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2009837CBFFD68F45FBED23B7F631A8B8F0E6E2E"
SERVARR_LIST_URL="https://apt.servarr.com/debian"

# Paths de config dos serviços
PLEX_CONFIG_DIR="/var/lib/plexmediaserver"
LIDARR_CONFIG_DIR="/var/lib/lidarr"
PROWLARR_CONFIG_DIR="/var/lib/prowlarr"
QBITTORRENT_CONFIG_DIR=""  # definido após TARGET_HOME

# Dependências APT
COMMON_DEPS=(
  curl
  wget
  gnupg
  apt-transport-https
  ca-certificates
  software-properties-common
  ntfs-3g
  ufw
  jq
  unzip
  sqlite3
  openssh-server
)

# Cores (podem ser desabilitadas com NO_COLOR=1)
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_DIM='\033[2m'
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_BLUE='\033[0;34m'
  C_CYAN='\033[0;36m'
  C_WHITE='\033[1;37m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_WHITE=''
fi

# Flags internas
ASSUME_YES=false
SKIP_SYSTEM_UPDATE=false
DRY_RUN=false
