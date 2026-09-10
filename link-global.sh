#!/usr/bin/env bash
# link-global.sh — Publica os scripts do projeto em /usr/local/bin via symlink
#
# O repositório continua sendo a fonte da verdade: qualquer edição nos .sh
# do projeto vale imediatamente nos comandos globais (não há cópia).
#
# Uso:
#   sudo ./link-global.sh              # cria/atualiza links
#   sudo ./link-global.sh --remove     # remove links deste projeto
#   sudo ./link-global.sh --dry-run    # só mostra o que faria
#   ./link-global.sh --list            # lista mapeamento (sem root)
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

BIN_DIR="${MSI_BIN_DIR:-/usr/local/bin}"
PREFIX="${MSI_PREFIX:-msi}"
DRY_RUN=false
REMOVE=false
LIST_ONLY=false

# comando_global → script no repo
declare -A COMMANDS=(
  ["${PREFIX}-install"]="install.sh"
  ["${PREFIX}-mount"]="mount.sh"
  ["${PREFIX}-update"]="update.sh"
  ["${PREFIX}-uninstall"]="uninstall.sh"
  ["${PREFIX}-setup-media"]="setup-media-stack.sh"
  ["${PREFIX}-setup-cloud-backup"]="setup-cloud-backup.sh"
  ["${PREFIX}-backup-cloud"]="backup-cloud.sh"
  ["${PREFIX}-setup-security"]="setup-security.sh"
  ["${PREFIX}-backup-restic"]="backup-restic.sh"
  ["${PREFIX}-restore-restic"]="restore-restic.sh"
  ["${PREFIX}-fix-servarr-auth"]="fix-servarr-auth.sh"
  ["${PREFIX}-reset-mount"]="reset-mount.sh"
  ["${PREFIX}-link-global"]="link-global.sh"
)

usage() {
  cat <<EOF
Uso: sudo ./link-global.sh [opções]

Cria symlinks em ${BIN_DIR} apontando para os scripts deste repositório.
Atualizações nos arquivos do projeto passam a valer nos comandos globais.

Opções:
  --remove     Remove os links (só os que apontam para este repo)
  --dry-run    Mostra ações sem alterar o sistema
  --list       Lista o mapeamento comando → script
  --bin DIR    Destino dos links (padrão: ${BIN_DIR})
  --prefix P   Prefixo dos comandos (padrão: ${PREFIX})
  -h, --help   Esta ajuda

Exemplos após instalar:
  sudo ${PREFIX}-mount
  sudo ${PREFIX}-backup-cloud --dry-run
  sudo ${PREFIX}-setup-security
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remove) REMOVE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --list) LIST_ONLY=true; shift ;;
      --bin)
        BIN_DIR="${2:?--bin requer um diretório}"
        shift 2
        ;;
      --prefix)
        PREFIX="${2:?--prefix requer um valor}"
        # Reconstrói o mapa com o novo prefixo
        COMMANDS=(
          ["${PREFIX}-install"]="install.sh"
          ["${PREFIX}-mount"]="mount.sh"
          ["${PREFIX}-update"]="update.sh"
          ["${PREFIX}-uninstall"]="uninstall.sh"
          ["${PREFIX}-setup-media"]="setup-media-stack.sh"
          ["${PREFIX}-setup-cloud-backup"]="setup-cloud-backup.sh"
          ["${PREFIX}-backup-cloud"]="backup-cloud.sh"
          ["${PREFIX}-setup-security"]="setup-security.sh"
          ["${PREFIX}-backup-restic"]="backup-restic.sh"
          ["${PREFIX}-restore-restic"]="restore-restic.sh"
          ["${PREFIX}-fix-servarr-auth"]="fix-servarr-auth.sh"
          ["${PREFIX}-reset-mount"]="reset-mount.sh"
          ["${PREFIX}-link-global"]="link-global.sh"
        )
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "Opção desconhecida: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

list_commands() {
  echo "Fonte: ${INSTALLER_ROOT}"
  echo "Destino: ${BIN_DIR}"
  echo
  local cmd script
  # Ordem estável
  for cmd in $(printf '%s\n' "${!COMMANDS[@]}" | sort); do
    script="${COMMANDS[$cmd]}"
    printf '  %-28s → %s/%s\n' "${cmd}" "${INSTALLER_ROOT}" "${script}"
  done
}

require_root_unless_dry() {
  if [[ "${LIST_ONLY}" == true || "${DRY_RUN}" == true ]]; then
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Execute com sudo (escreve em ${BIN_DIR}):" >&2
    echo "  sudo ${INSTALLER_ROOT}/link-global.sh $*" >&2
    exit 1
  fi
}

link_path_ok() {
  local link="$1"
  local target="$2"
  [[ -L "${link}" ]] || return 1
  local current
  current="$(realpath "${link}" 2>/dev/null || true)"
  [[ "${current}" == "$(realpath "${target}")" ]]
}

points_to_this_repo() {
  local link="$1"
  [[ -L "${link}" ]] || return 1
  local current
  current="$(realpath "${link}" 2>/dev/null || true)"
  [[ -n "${current}" && "${current}" == "${INSTALLER_ROOT}/"* ]]
}

do_link() {
  local cmd="$1"
  local script="$2"
  local target="${INSTALLER_ROOT}/${script}"
  local link="${BIN_DIR}/${cmd}"

  if [[ ! -f "${target}" ]]; then
    echo "⚠  ausente no repo, pulando: ${script}" >&2
    return 0
  fi
  if [[ ! -x "${target}" ]]; then
    chmod +x "${target}" || true
  fi

  if link_path_ok "${link}" "${target}"; then
    echo "✓  já ok: ${link}"
    return 0
  fi

  if [[ -e "${link}" || -L "${link}" ]]; then
    if points_to_this_repo "${link}"; then
      echo "↻  atualizando: ${link}"
    elif [[ -L "${link}" ]]; then
      echo "⚠  ${link} já existe (outro destino) — sobrescrevendo" >&2
    else
      echo "✗  ${link} existe e não é symlink — pulando" >&2
      return 0
    fi
    if [[ "${DRY_RUN}" == true ]]; then
      echo "   (dry-run) rm -f ${link} && ln -s ${target} ${link}"
      return 0
    fi
    rm -f "${link}"
  else
    echo "+  criando: ${link} → ${target}"
    if [[ "${DRY_RUN}" == true ]]; then
      echo "   (dry-run) ln -s ${target} ${link}"
      return 0
    fi
  fi

  ln -s "${target}" "${link}"
}

do_remove() {
  local cmd="$1"
  local link="${BIN_DIR}/${cmd}"

  if [[ ! -e "${link}" && ! -L "${link}" ]]; then
    echo "·  já ausente: ${link}"
    return 0
  fi

  if ! points_to_this_repo "${link}"; then
    echo "⚠  ${link} não aponta para este repo — não removido" >&2
    return 0
  fi

  echo "-  removendo: ${link}"
  if [[ "${DRY_RUN}" == true ]]; then
    echo "   (dry-run) rm -f ${link}"
    return 0
  fi
  rm -f "${link}"
}

main() {
  parse_args "$@"

  if [[ "${LIST_ONLY}" == true ]]; then
    list_commands
    exit 0
  fi

  require_root_unless_dry "$@"

  if [[ "${DRY_RUN}" != true ]]; then
    mkdir -p "${BIN_DIR}"
  fi

  echo "Projeto (fonte da verdade): ${INSTALLER_ROOT}"
  echo "Links em: ${BIN_DIR} (prefixo: ${PREFIX}-*)"
  echo

  local cmd script
  for cmd in $(printf '%s\n' "${!COMMANDS[@]}" | sort); do
    script="${COMMANDS[$cmd]}"
    if [[ "${REMOVE}" == true ]]; then
      do_remove "${cmd}"
    else
      do_link "${cmd}" "${script}"
    fi
  done

  echo
  if [[ "${REMOVE}" == true ]]; then
    echo "Links removidos (quando apontavam para este repo)."
  else
    echo "Pronto. Em qualquer terminal:"
    echo "  sudo ${PREFIX}-mount"
    echo "  sudo ${PREFIX}-backup-cloud"
    echo "  ${PREFIX}-link-global --list"
  fi
}

main "$@"
