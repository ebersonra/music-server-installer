# ADR-0001 — Migração systemd → Docker Compose

**Status:** Aceito  
**Data:** 2026-09-14  
**Atualizado:** 2026-09-15 (Plex `network_mode: host` + `ADVERTISE_IP`)  
**Substitui:** instalação nativa via units systemd (`templates/systemd/*`)  
**Guia operacional:** [docs/docker.md](../docker.md)

## Contexto

O Music Server Installer instalava Plex, Lidarr, Prowlarr, qBittorrent e FlareSolverr como binários/APT com units systemd. Isso acoplava o stack à distro, dificultava upgrades previsíveis e exigia dependências de sistema (ex.: Xvfb/Chromium para FlareSolverr).

## Decisão

1. **Runtime padrão:** Docker Compose (`docker compose`) com um único `docker-compose.yml` na raiz do repositório.
2. **Imagens:** LinuxServer.io para Lidarr, Prowlarr, qBittorrent e Plex; imagem oficial `ghcr.io/flaresolverr/flaresolverr` para FlareSolverr.
3. **Versionamento:** tags sempre na **última release estável** (`latest` / track estável). Nunca `nightly` / `develop`. Variáveis em `.env` (`*_IMAGE`, `*_TAG`) — ver `docs/docker-versioning.md`.
4. **Dados:** bind mounts nos caminhos já usados (`/var/lib/...`, biblioteca em `$MOUNT_POINT` no **mesmo path** dentro do container).
5. **Rede:**
   - Bridge `music-server` para FlareSolverr, qBittorrent, Prowlarr e Lidarr (DNS interno; FlareSolverr só em `127.0.0.1:8191`).
   - **Plex em `network_mode: host`** + `ADVERTISE_IP` / `ALLOWED_NETWORKS`, para discovery GDM e app mobile na LAN. Bridge sozinha anuncia IP do container e o app fica *offline*.
6. **Host permanece responsável por:** montagem do disco (`msi-mount`/`mount.sh`/fstab), UFW, SSH/SFTP, Fail2Ban e backups restic/rclone (timers systemd auxiliares).
7. **CLI global:** `link-global.sh` / `msi-link-global` publica `msi-*`, incluindo `msi-migrate-docker` e `msi-update` (pull estável).

## Consequências

- **Mais fácil:** upgrades (`docker compose pull` / `msi-update`), isolamento de deps, mesma stack em qualquer Ubuntu/Debian com Docker; app Plex na Wi‑Fi com host network.
- **Mais difícil:** exige Docker + Compose v2; wiring interno usa hostnames de serviço (`qbittorrent`, `flaresolverr`, …); Plex não participa da bridge (não resolve `lidarr` por DNS — e não precisa).
- **Fora de escopo:** orquestração Kubernetes; migrar Fail2Ban/restic para containers nesta ADR.

## Impacto SRE / DevSecOps

- **Observabilidade:** `docker compose ps` / `docker compose logs`; healthchecks HTTP nos serviços web.
- **Rollback:** `docker compose down` + reabilitar unit systemd (legado) ou `compose up` com tag anterior pinada em `.env`.
- **Segurança no ciclo:** imagens oficiais; segredos (claim token Plex, senha qBit) via `.env` / arquivos de estado — nunca commitados; FlareSolverr sem exposição pública.
