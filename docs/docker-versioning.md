# Versionamento de imagens Docker

Padrão do Music Server Installer ([ADR-0001](adrs/ADR-0001-migracao-systemd-para-docker.md)).  
Operação do stack: [docker.md](docker.md).

## Regra

Sempre a **última release estável** de cada imagem. Nunca tags de desenvolvimento.

| Permitido | Proibido |
|-----------|----------|
| `latest` (track estável do maintainer) | `nightly`, `develop`, `unstable` |
| Tag de versão estável explícita (`2.5.2`, `version-2.5.2.5491`) | tags de pré-release |

## Onde configurar

Arquivo `.env` (cópia de `.env.example`) na raiz do repositório:

```bash
LIDARR_IMAGE=lscr.io/linuxserver/lidarr
LIDARR_TAG=latest
```

No `docker-compose.yml`:

```yaml
image: ${LIDARR_IMAGE}:${LIDARR_TAG}
```

Imagens atuais do projeto:

| Serviço | Imagem | Tag padrão |
|---------|--------|------------|
| FlareSolverr | `ghcr.io/flaresolverr/flaresolverr` | `latest` |
| qBittorrent | `lscr.io/linuxserver/qbittorrent` | `latest` |
| Prowlarr | `lscr.io/linuxserver/prowlarr` | `latest` |
| Lidarr | `lscr.io/linuxserver/lidarr` | `latest` |
| Plex | `lscr.io/linuxserver/plex` | `latest` |

## Atualizar

Na pasta do repositório (com `.env` presente):

```bash
sudo msi-update
# equivalente:
docker compose pull
docker compose up -d
```

`msi-update` / `update.sh` faz pull da tag estável e recria os containers.

## Pin opcional

Para auditoria/reprodutibilidade, troque `*_TAG=latest` pela versão estável concreta (Hub / GHCR). A política do projeto continua sendo “acompanhar estável”; o pin é exceção documentada.
