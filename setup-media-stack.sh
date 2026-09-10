#!/usr/bin/env bash
# setup-media-stack.sh — Liga Lidarr ↔ Prowlarr ↔ qBittorrent ↔ FlareSolverr
# Idempotente: pode rodar após install ou em stack já existente.
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=common.sh
source "${INSTALLER_ROOT}/common.sh"

FROM_INSTALL=false
QBIT_PASSWORD=""
# Nomes-isca comuns (release profile Lidarr)
TRAP_IGNORED=("BROADCAST" "SODAPOP" "RARBG" "EVO" "SPARKS" "FGT")

usage() {
  cat <<EOF
Uso: sudo ./setup-media-stack.sh [opções]

Configura automaticamente:
  - Lidarr: root folder Artistas/, cliente qBittorrent, failed download, blocklist
  - Prowlarr: app Lidarr (Full Sync) + proxy FlareSolverr
  - qBittorrent: exclusões de arquivos perigosos (se conf existir)

Opções:
  -y, --yes              Não pedir confirmação
  --from-install         Chamado pelo install.sh (menos verboso)
  --qbit-password SENHA  Senha do WebUI do qBittorrent (senão tenta temp/vazia)
  -h, --help             Esta ajuda
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=true; shift ;;
      --from-install) FROM_INSTALL=true; ASSUME_YES=true; shift ;;
      --qbit-password)
        QBIT_PASSWORD="${2:?}"
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

_read_api_key() {
  local config_xml="$1"
  if [[ ! -f "${config_xml}" ]]; then
    echo ""
    return 1
  fi
  # Preferir grep+sed (sem depender de xmlstarlet)
  local key
  key="$(grep -oP '(?<=<ApiKey>)[^<]+' "${config_xml}" 2>/dev/null || true)"
  if [[ -z "${key}" ]]; then
    key="$(sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "${config_xml}" | head -1)"
  fi
  printf '%s' "${key}"
}

_wait_http() {
  local url="$1"
  local timeout="${2:-60}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if curl -fsS -o /dev/null --connect-timeout 2 "${url}" 2>/dev/null; then
      return 0
    fi
    # APIs Servarr respondem 401 sem key — ainda assim “up”
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 "${url}" 2>/dev/null || echo 000)"
    if [[ "${code}" =~ ^(200|301|302|401|404)$ ]]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

_api_get() {
  local base="$1" key="$2" path="$3"
  curl -fsS -H "X-Api-Key: ${key}" "${base}${path}"
}

_api_post() {
  local base="$1" key="$2" path="$3" body="$4"
  curl -fsS -X POST -H "X-Api-Key: ${key}" -H "Content-Type: application/json" \
    -d "${body}" "${base}${path}"
}

_api_put() {
  local base="$1" key="$2" path="$3" body="$4"
  curl -fsS -X PUT -H "X-Api-Key: ${key}" -H "Content-Type: application/json" \
    -d "${body}" "${base}${path}"
}

_resolve_qbit_password() {
  if [[ -n "${QBIT_PASSWORD}" ]]; then
    return 0
  fi
  if [[ -f "${STATE_DIR}/qbittorrent-temp-password.txt" ]]; then
    QBIT_PASSWORD="$(tr -d '\n' < "${STATE_DIR}/qbittorrent-temp-password.txt")"
  fi
}

_ensure_lidarr_root_folder() {
  local base="$1" key="$2" path="$3"
  local existing
  existing="$(_api_get "${base}" "${key}" "/api/v1/rootfolder" 2>/dev/null || echo '[]')"
  if echo "${existing}" | jq -e --arg p "${path}" 'map(.path) | index($p) != null' >/dev/null 2>&1; then
    log_ok "Lidarr root folder já existe: ${path}"
    return 0
  fi
  mkdir -p "${path}"
  _api_post "${base}" "${key}" "/api/v1/rootfolder" "$(jq -nc --arg p "${path}" '{path:$p}')" >/dev/null
  log_ok "Lidarr root folder criado: ${path}"
}

_ensure_lidarr_qbittorrent() {
  local base="$1" key="$2"
  local port="${PORT_QBITTORRENT}"
  local clients
  clients="$(_api_get "${base}" "${key}" "/api/v1/downloadclient" 2>/dev/null || echo '[]')"

  if echo "${clients}" | jq -e 'map(select(.implementation=="QBittorrent" or (.name|ascii_downcase|contains("qbit")))) | length > 0' >/dev/null 2>&1; then
    log_ok "Lidarr já tem download client qBittorrent"
    return 0
  fi

  local schema
  schema="$(_api_get "${base}" "${key}" "/api/v1/downloadclient/schema" 2>/dev/null || echo '[]')"
  local template
  template="$(echo "${schema}" | jq -c '[.[] | select(.implementation=="QBittorrent")][0] // empty')"
  if [[ -z "${template}" || "${template}" == "null" ]]; then
    log_warn "Schema QBittorrent não encontrado na API do Lidarr — configure o client manualmente"
    return 1
  fi

  _resolve_qbit_password

  local body
  body="$(echo "${template}" | jq -c \
    --arg host "127.0.0.1" \
    --argjson port "${port}" \
    --arg user "admin" \
    --arg pass "${QBIT_PASSWORD}" \
    --arg cat "lidarr" \
    '
    .name = "qBittorrent"
    | .enable = true
    | .priority = 1
    | .fields |= map(
        if .name == "host" then .value = $host
        elif .name == "port" then .value = $port
        elif .name == "username" then .value = $user
        elif .name == "password" then .value = $pass
        elif .name == "musicCategory" or .name == "category" then .value = $cat
        elif .name == "removeCompletedDownloads" then .value = true
        elif .name == "removeFailedDownloads" then .value = true
        else .
        end
      )
    ')"

  if _api_post "${base}" "${key}" "/api/v1/downloadclient" "${body}" >/dev/null 2>&1; then
    log_ok "Lidarr: download client qBittorrent adicionado"
  else
    log_warn "Falha ao adicionar qBittorrent no Lidarr (senha WebUI?). Use --qbit-password ou configure na UI"
    return 1
  fi
}

_ensure_lidarr_failed_handling() {
  local base="$1" key="$2"
  local cfg
  cfg="$(_api_get "${base}" "${key}" "/api/v1/config/downloadclient" 2>/dev/null || echo '')"
  if [[ -z "${cfg}" ]]; then
    log_warn "Não foi possível ler config downloadclient do Lidarr"
    return 1
  fi

  local body
  body="$(echo "${cfg}" | jq -c '
    .enableCompletedDownloadHandling = true
    | .autoRedownloadFailed = true
    | .autoRedownloadFailedFromInteractiveSearch = true
  ')"

  # failedDownloadHandling pode ser bool ou objeto conforme versão
  if echo "${cfg}" | jq -e 'has("failedDownloadHandling")' >/dev/null 2>&1; then
    if echo "${cfg}" | jq -e '.failedDownloadHandling | type == "boolean"' >/dev/null 2>&1; then
      body="$(echo "${body}" | jq -c '.failedDownloadHandling = true')"
    elif echo "${cfg}" | jq -e '.failedDownloadHandling | type == "object"' >/dev/null 2>&1; then
      body="$(echo "${body}" | jq -c '.failedDownloadHandling.enabled = true')"
    fi
  fi

  local id
  id="$(echo "${cfg}" | jq -r '.id')"
  if [[ -n "${id}" && "${id}" != "null" ]]; then
    _api_put "${base}" "${key}" "/api/v1/config/downloadclient/${id}" "${body}" >/dev/null
    log_ok "Lidarr: completed/failed download handling habilitado"
  else
    log_warn "Lidarr: id de downloadclient config ausente — pulando failed handling"
  fi
}

_ensure_lidarr_release_profile() {
  local base="$1" key="$2"
  local profiles name="MSI-blocklist-armadilhas"
  profiles="$(_api_get "${base}" "${key}" "/api/v1/releaseprofile" 2>/dev/null || echo '[]')"

  if echo "${profiles}" | jq -e --arg n "${name}" 'map(.name) | index($n) != null' >/dev/null 2>&1; then
    log_ok "Lidarr release profile já existe: ${name}"
    return 0
  fi

  local ignored_json
  ignored_json="$(printf '%s\n' "${TRAP_IGNORED[@]}" | jq -R . | jq -s -c .)"

  local body
  body="$(jq -nc \
    --arg name "${name}" \
    --argjson ignored "${ignored_json}" \
    '{
      name: $name,
      enabled: true,
      indexerId: 0,
      required: [],
      ignored: $ignored,
      preferred: [],
      includePreferredWhenRenaming: false
    }')"

  if _api_post "${base}" "${key}" "/api/v1/releaseprofile" "${body}" >/dev/null 2>&1; then
    log_ok "Lidarr: release profile de armadilhas criado"
  else
    log_warn "Lidarr: não foi possível criar release profile (API pode diferir)"
  fi
}

_ensure_lidarr_min_sizes() {
  local base="$1" key="$2"
  local defs
  defs="$(_api_get "${base}" "${key}" "/api/v1/qualitydefinition" 2>/dev/null || echo '[]')"
  if [[ "${defs}" == "[]" || -z "${defs}" ]]; then
    return 0
  fi

  # Evitar fakes minúsculos; singles legítimos raramente ficam abaixo de ~2 MB
  local updated
  updated="$(echo "${defs}" | jq -c 'map(if (.minSize == null or .minSize < 2) then .minSize = 2 else . end)')"

  if _api_put "${base}" "${key}" "/api/v1/qualitydefinition" "${updated}" >/dev/null 2>&1; then
    log_ok "Lidarr: tamanho mínimo de qualidade ≥ 2 MB"
  else
    # Algumas versões exigem PUT por item
    local item
    while IFS= read -r item; do
      [[ -z "${item}" ]] && continue
      local id
      id="$(echo "${item}" | jq -r '.id')"
      _api_put "${base}" "${key}" "/api/v1/qualitydefinition/${id}" "${item}" >/dev/null 2>&1 || true
    done < <(echo "${updated}" | jq -c '.[]')
    log_ok "Lidarr: tentou aplicar minSize nas quality definitions"
  fi
}

_ensure_prowlarr_lidarr_app() {
  local prow_base="$1" prow_key="$2" lidarr_base="$3" lidarr_key="$4"
  local apps
  apps="$(_api_get "${prow_base}" "${prow_key}" "/api/v1/applications" 2>/dev/null || echo '[]')"

  if echo "${apps}" | jq -e 'map(select(.implementation=="Lidarr" or (.name|ascii_downcase|contains("lidarr")))) | length > 0' >/dev/null 2>&1; then
    log_ok "Prowlarr já tem app Lidarr"
    return 0
  fi

  local schema
  schema="$(_api_get "${prow_base}" "${prow_key}" "/api/v1/applications/schema" 2>/dev/null || echo '[]')"
  local template
  template="$(echo "${schema}" | jq -c '[.[] | select(.implementation=="Lidarr")][0] // empty')"
  if [[ -z "${template}" || "${template}" == "null" ]]; then
    log_warn "Schema Lidarr não encontrado no Prowlarr"
    return 1
  fi

  local body
  body="$(echo "${template}" | jq -c \
    --arg prow "http://127.0.0.1:${PORT_PROWLARR}" \
    --arg lidarr "${lidarr_base}" \
    --arg apikey "${lidarr_key}" \
    '
    .name = "Lidarr"
    | .syncLevel = "fullSync"
    | .fields |= map(
        if (.name | test("prowlarrUrl|ProwlarrUrl"; "i")) then .value = $prow
        elif (.name | test("^baseUrl$"; "i")) then .value = $lidarr
        elif (.name | test("apiKey"; "i")) then .value = $apikey
        else .
        end
      )
    ')"

  if _api_post "${prow_base}" "${prow_key}" "/api/v1/applications" "${body}" >/dev/null 2>&1; then
    log_ok "Prowlarr: app Lidarr (Full Sync) adicionado"
  else
    log_warn "Falha ao adicionar Lidarr no Prowlarr — configure em Settings → Apps"
    return 1
  fi
}

_ensure_prowlarr_flaresolverr() {
  local prow_base="$1" prow_key="$2"
  local host="${FLARESOLVERR_HOST:-127.0.0.1}"
  local port="${PORT_FLARESOLVERR:-8191}"
  local url="http://${host}:${port}/"

  local proxies
  proxies="$(_api_get "${prow_base}" "${prow_key}" "/api/v1/indexerProxy" 2>/dev/null || echo '[]')"

  if echo "${proxies}" | jq -e 'map(select(.implementation=="FlareSolverr" or (.name|ascii_downcase|contains("flare")))) | length > 0' >/dev/null 2>&1; then
    log_ok "Prowlarr já tem proxy FlareSolverr"
    return 0
  fi

  local schema
  schema="$(_api_get "${prow_base}" "${prow_key}" "/api/v1/indexerProxy/schema" 2>/dev/null || echo '[]')"
  local template
  template="$(echo "${schema}" | jq -c '[.[] | select(.implementation=="FlareSolverr")][0] // empty')"
  if [[ -z "${template}" || "${template}" == "null" ]]; then
    log_warn "Schema FlareSolverr não encontrado no Prowlarr"
    return 1
  fi

  local body
  body="$(echo "${template}" | jq -c \
    --arg url "${url}" \
    '
    .name = "FlareSolverr"
    | .fields |= map(
        if (.name | test("host|url|baseUrl"; "i")) then .value = $url
        else .
        end
      )
    ')"

  if _api_post "${prow_base}" "${prow_key}" "/api/v1/indexerProxy" "${body}" >/dev/null 2>&1; then
    log_ok "Prowlarr: proxy FlareSolverr adicionado (${url})"
  else
    log_warn "Falha ao adicionar FlareSolverr no Prowlarr — configure em Indexer Proxies"
    return 1
  fi
}

_apply_qbit_exclusions_from_state() {
  if [[ "${INSTALL_QBITTORRENT}" != "true" ]]; then
    return 0
  fi
  if [[ -z "${TARGET_HOME:-}" ]]; then
    return 0
  fi
  local conf="${TARGET_HOME}/.config/qBittorrent/qBittorrent.conf"
  if [[ ! -f "${conf}" ]]; then
    return 0
  fi
  # Reusa helper se qbittorrent.sh estiver sourced; senão inline mínimo
  if declare -f _qbit_apply_excluded_file_names >/dev/null; then
    _qbit_apply_excluded_file_names "${conf}"
  else
    # shellcheck source=services/qbittorrent.sh
    source "${INSTALLER_ROOT}/services/qbittorrent.sh"
    _qbit_apply_excluded_file_names "${conf}"
  fi
  if [[ -n "${TARGET_UID:-}" ]]; then
    chown "${TARGET_UID}:${TARGET_GID}" "${conf}" 2>/dev/null || true
  fi
  log_ok "qBittorrent: exclusões de arquivos perigosos aplicadas"
}

main() {
  parse_args "$@"
  require_root

  if [[ "${FROM_INSTALL}" != "true" ]]; then
    print_banner
    echo -e "${C_BOLD}Setup do stack de mídia (wiring)${C_RESET}"
    echo
  fi

  if ! load_state; then
    die "Nenhuma instalação encontrada (${STATE_FILE}). Execute ./install.sh primeiro."
  fi

  MUSIC_ROOT="${MUSIC_ROOT:-${MOUNT_POINT}/Musicas}"
  local artistas="${MUSIC_ROOT}/Artistas"
  local lidarr_base="http://127.0.0.1:${PORT_LIDARR}"
  local prow_base="http://127.0.0.1:${PORT_PROWLARR}"

  if [[ "${FROM_INSTALL}" != "true" ]]; then
    echo -e "  Lidarr:       ${INSTALL_LIDARR}"
    echo -e "  Prowlarr:     ${INSTALL_PROWLARR}"
    echo -e "  qBittorrent:  ${INSTALL_QBITTORRENT}"
    echo -e "  FlareSolverr: ${INSTALL_FLARESOLVERR:-false}"
    echo -e "  Artistas:     ${artistas}"
    echo
    if ! confirm "Aplicar wiring agora?"; then
      die "Cancelado."
    fi
  fi

  _apply_qbit_exclusions_from_state || true

  local lidarr_key="" prow_key=""

  if [[ "${INSTALL_LIDARR}" == "true" ]]; then
    log_step "Aguardando Lidarr"
    if ! _wait_http "${lidarr_base}/ping" 90 && ! _wait_http "${lidarr_base}" 30; then
      log_warn "Lidarr não respondeu a tempo"
    else
      lidarr_key="$(_read_api_key "${LIDARR_CONFIG_DIR}/config.xml")"
      if [[ -z "${lidarr_key}" ]]; then
        log_warn "ApiKey do Lidarr não encontrada em ${LIDARR_CONFIG_DIR}/config.xml"
      else
        _ensure_lidarr_root_folder "${lidarr_base}" "${lidarr_key}" "${artistas}" || true
        _ensure_lidarr_qbittorrent "${lidarr_base}" "${lidarr_key}" || true
        _ensure_lidarr_failed_handling "${lidarr_base}" "${lidarr_key}" || true
        _ensure_lidarr_release_profile "${lidarr_base}" "${lidarr_key}" || true
        _ensure_lidarr_min_sizes "${lidarr_base}" "${lidarr_key}" || true
      fi
    fi
  fi

  if [[ "${INSTALL_PROWLARR}" == "true" ]]; then
    log_step "Aguardando Prowlarr"
    if ! _wait_http "${prow_base}/ping" 90 && ! _wait_http "${prow_base}" 30; then
      log_warn "Prowlarr não respondeu a tempo"
    else
      prow_key="$(_read_api_key "${PROWLARR_CONFIG_DIR}/config.xml")"
      if [[ -z "${prow_key}" ]]; then
        log_warn "ApiKey do Prowlarr não encontrada"
      else
        if [[ -n "${lidarr_key}" ]]; then
          _ensure_prowlarr_lidarr_app "${prow_base}" "${prow_key}" "${lidarr_base}" "${lidarr_key}" || true
        fi
        if [[ "${INSTALL_FLARESOLVERR}" == "true" ]]; then
          if _wait_http "http://${FLARESOLVERR_HOST:-127.0.0.1}:${PORT_FLARESOLVERR}" 60; then
            _ensure_prowlarr_flaresolverr "${prow_base}" "${prow_key}" || true
          else
            log_warn "FlareSolverr não respondeu — proxy não configurado"
          fi
        fi
      fi
    fi
  fi

  echo
  log_ok "Wiring do media stack concluído"
  if [[ "${FROM_INSTALL}" != "true" ]]; then
    echo -e "${C_DIM}Próximo: adicione indexadores no Prowlarr (música) e peça álbuns no Lidarr.${C_RESET}"
    echo -e "${C_DIM}Guia: docs/how-to.md${C_RESET}"
  fi
}

main "$@"
