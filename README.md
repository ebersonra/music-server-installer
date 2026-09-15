# Music Server Installer

Instalador interativo em Bash para montar um servidor de músicas no **Ubuntu/Debian**, no estilo CasaOS/Umbrel.

Os serviços de mídia rodam em **Docker Compose** — guia completo: **[docs/docker.md](docs/docker.md)** · decisão: [ADR-0001](docs/adrs/ADR-0001-migracao-systemd-para-docker.md) · tags: [docs/docker-versioning.md](docs/docker-versioning.md).

| Serviço         | Porta   | Rede Compose | Função |
|-----------------|---------|--------------|--------|
| **Plex**        | `32400` | **host** (app mobile / GDM) | Músicas + fotos |
| **Lidarr**      | `8686`  | bridge `music-server` | Pedir / gerenciar álbuns |
| **Prowlarr**    | `9696`  | bridge | Indexadores |
| **FlareSolverr**| `8191`  | bridge (só localhost) | Cloudflare/captcha |
| **qBittorrent** | `8080`  | bridge | Downloads |

Também detecta discos (NTFS/USB), cria pastas, ajusta permissões, abre portas no firewall e liga Lidarr ↔ Prowlarr ↔ qBit ↔ FlareSolverr (`msi-setup-media`).

```
Lidarr → Prowlarr + FlareSolverr → qBittorrent → Lidarr (Artistas/) → Plex
```

Diagrama: [docs/arquitetura-musica.png](docs/arquitetura-musica.png).

---

## Estrutura

```
music-server-installer/
├── docker-compose.yml      # Stack (5 serviços)
├── .env.example            # Modelo de paths / tags / PLEX_ADVERTISE_IP
├── install.sh              # Instalação interativa → Compose
├── migrate-to-docker.sh    # systemd legado → Docker
├── update.sh               # pull latest estável + recreate
├── link-global.sh          # publica msi-* 
├── services/docker.sh
└── docs/
    ├── docker.md           # ★ guia Docker / Compose
    ├── docker-versioning.md
    ├── how-to.md
    └── adrs/ADR-0001-…
```

---

## Requisitos

- Ubuntu 20.04+ ou Debian 11+
- `sudo`
- **Docker** + **Compose v2** (`docker compose`)
- Disco para a biblioteca
- Rede local

---

## Instalação rápida

```bash
git clone https://github.com/ebersonra/music-server-installer.git
cd music-server-installer
sudo ./install.sh
sudo ./link-global.sh
```

### Compose manual

```bash
cp .env.example .env
# PUID/PGID, MOUNT_POINT, PLEX_ADVERTISE_IP=http://SEU_IP:32400/
docker compose pull && docker compose up -d
sudo msi-setup-media    # após link-global; ou ./setup-media-stack.sh
```

Detalhes: **[docs/docker.md](docs/docker.md)**.

### Já tinha systemd?

```bash
sudo msi-migrate-docker -y
```

---

## Pastas

```
/media/music/Musicas/Artistas/     # Lidarr + Plex Music
/media/music/Musicas/Downloads/    # qBittorrent
/media/music/Fotos/                # Plex Photos + FolderSync
```

| Guia | Arquivo |
|------|---------|
| **Docker / Compose** | [docs/docker.md](docs/docker.md) |
| Baixar músicas | [docs/how-to.md](docs/how-to.md) |
| Fotos / FolderSync | [docs/plex-photos.md](docs/plex-photos.md), [docs/foldersync.md](docs/foldersync.md) |
| Backup / segurança | [docs/cloud-backup.md](docs/cloud-backup.md), [docs/security.md](docs/security.md) |
| Tags de imagem | [docs/docker-versioning.md](docs/docker-versioning.md) |

---

## Após instalar

```
Plex         http://IP:32400/web
Lidarr       http://IP:8686
Prowlarr     http://IP:9696
qBittorrent  http://IP:8080
FlareSolverr http://127.0.0.1:8191
```

```bash
docker logs music-qbittorrent 2>&1 | grep -i password   # senha WebUI
sudo msi-setup-media                                    # wiring
sudo msi-fix-servarr-auth                               # se HTTP 500 no Servarr
```

**App Plex offline na Wi‑Fi?** Veja [docs/docker.md § Plex e app mobile](docs/docker.md#plex-e-app-mobile) (`network_mode: host` + `PLEX_ADVERTISE_IP`).

---

## Comandos `msi-*` e Compose

```bash
sudo ./link-global.sh
msi-link-global --list
```

| Comando | Função |
|---------|--------|
| `sudo msi-install` | Instalação (Docker) |
| `sudo msi-migrate-docker` | Migra systemd → Docker |
| `sudo msi-update` | `docker compose pull` + recreate |
| `sudo msi-setup-media` | Wiring das APIs |
| `sudo msi-mount` | Remonta o HD |
| `sudo msi-uninstall` | Remove containers |
| `sudo msi-fix-servarr-auth` | Auth Lidarr/Prowlarr |
| `sudo msi-setup-security` / `msi-backup-restic` / `msi-restore-restic` | Segurança + restic |
| `sudo msi-setup-cloud-backup` / `msi-backup-cloud` | Backup nuvem |
| `msi-link-global` | Gerencia symlinks |

```bash
cd /caminho/do/repo
docker compose ps
docker compose logs -f plex
docker compose restart lidarr
docker compose pull && docker compose up -d
```

Timers de backup/segurança ficam no **host** (`systemctl status music-server-restic.timer`, etc.).

---

## Problemas comuns

```bash
# Status
docker compose ps
docker compose logs --tail 80 <serviço>

# Porta / unit legado
sudo systemctl stop lidarr prowlarr flaresolverr plexmediaserver
sudo systemctl stop "qbittorrent-nox@$USER"

# HD
sudo msi-mount
sudo msi-reset-mount
```

Mais: [docs/docker.md § Troubleshooting](docs/docker.md#troubleshooting).

---

## Estado

```
/var/lib/music-server-installer/install.state
.env    # na raiz do repo — não versionar
```

---

## Licença

Uso livre para fins pessoais. Respeite a legislação local e os termos dos serviços/indexadores.
