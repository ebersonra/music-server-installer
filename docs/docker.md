# Docker e Docker Compose

Guia operacional do stack de mídia ([ADR-0001](adrs/ADR-0001-migracao-systemd-para-docker.md)).  
Versionamento de imagens: [docker-versioning.md](docker-versioning.md).

## Visão geral

| Serviço | Container | Rede | Porta no host |
|---------|-----------|------|----------------|
| FlareSolverr | `music-flaresolverr` | bridge `music-server` | `127.0.0.1:8191` |
| qBittorrent | `music-qbittorrent` | bridge | `8080` (+ BT `6881` tcp/udp) |
| Prowlarr | `music-prowlarr` | bridge | `9696` |
| Lidarr | `music-lidarr` | bridge | `8686` |
| Plex | `music-plex` | **`host`** | `32400` (+ GDM UDP `32410–32414`) |

```text
                    LAN / app mobile
                           │
                     Plex (host network)
                     ADVERTISE_IP=http://LAN:32400/
                           │
                     /media/music (bind)
                           │
    ┌──────────────────────┴──────────────────────┐
    │           bridge: music-server              │
    │  flaresolverr ← prowlarr ←→ lidarr          │
    │                    ↕                        │
    │               qbittorrent                   │
    └─────────────────────────────────────────────┘
```

- **Bridge** (`music-server`): DNS interno (`http://lidarr:8686`, `http://qbittorrent:8080`, `http://flaresolverr:8191`).
- **Plex em `network_mode: host`**: discovery GDM e app mobile na Wi‑Fi. Em bridge pura o app costuma ficar *offline*.

Arquivos:

| Arquivo | Função |
|---------|--------|
| `docker-compose.yml` | Definição dos 5 serviços |
| `.env` | Paths, PUID/PGID, tags, `PLEX_ADVERTISE_IP` (não versionar) |
| `.env.example` | Modelo sem segredos |

---

## Pré-requisitos

```bash
docker --version
docker compose version    # Compose v2 (plugin)
```

O `msi-install` / `install.sh` instala `docker.io` e tenta `docker-compose-v2` se faltar.

Usuário no grupo `docker` (ou use `sudo` nos comandos Compose).

---

## Subir o stack

### Via instalador (recomendado)

```bash
sudo msi-install
sudo msi-link-global          # se ainda não publicou os msi-*
sudo msi-setup-media          # wiring Lidarr ↔ Prowlarr ↔ qBit ↔ FlareSolverr
```

### Via Compose manual

Na raiz do repositório:

```bash
cp .env.example .env
# Ajuste PUID/PGID, MOUNT_POINT, *_CONFIG_DIR e:
#   PLEX_ADVERTISE_IP=http://SEU_IP_LAN:32400/

docker compose pull
docker compose up -d
docker compose ps
```

Subir só um serviço:

```bash
docker compose up -d flaresolverr
docker compose up -d qbittorrent
docker compose up -d prowlarr
docker compose up -d lidarr
docker compose up -d plex
```

Migrar instalação systemd antiga:

```bash
sudo msi-migrate-docker -y
```

---

## Variáveis importantes (`.env`)

| Variável | Exemplo | Notas |
|----------|---------|--------|
| `PUID` / `PGID` | `1000` / `984` | UID do usuário + GID do grupo `media` |
| `MOUNT_POINT` | `/media/music` | Montado no **mesmo path** dentro dos containers (exceto FlareSolverr) |
| `LIDARR_CONFIG_DIR` etc. | `/var/lib/lidarr` | Bind → `/config` (LinuxServer) |
| `*_TAG` | `latest` | Sempre release **estável** — ver [docker-versioning.md](docker-versioning.md) |
| `PLEX_ADVERTISE_IP` | `http://192.168.0.19:32400/` | URL que o Plex anuncia ao app / plex.tv |
| `PLEX_ALLOWED_NETWORKS` | `192.168.0.0/16,…` | Redes locais sem exigir relay |
| `PLEX_CLAIM` | (vazio se já claimado) | Só no 1º setup |

O instalador preenche `PLEX_ADVERTISE_IP` com o IP da LAN quando está vazio.

---

## Comandos do dia a dia

Execute na pasta do clone (onde estão `docker-compose.yml` e `.env`):

```bash
# Status
docker compose ps
docker compose logs -f plex
docker compose logs --tail 100 lidarr

# Reiniciar
docker compose restart plex
docker compose restart lidarr prowlarr

# Parar / subir tudo
docker compose stop
docker compose start
docker compose down          # remove containers (volumes/bind no host ficam)

# Atualizar imagens (última estável)
sudo msi-update
# ou:
docker compose pull && docker compose up -d
```

Equivalente global (após `msi-link-global`):

| Tarefa | Comando |
|--------|---------|
| Instalar | `sudo msi-install` |
| Atualizar imagens | `sudo msi-update` |
| Wiring APIs | `sudo msi-setup-media` |
| Remonta HD | `sudo msi-mount` |
| Desinstalar containers | `sudo msi-uninstall` |

---

## Wiring entre serviços

Após os containers saudáveis:

```bash
sudo msi-setup-media
```

Configura (idempotente):

- Lidarr → download client **`qbittorrent:8080`**
- Prowlarr → app Lidarr **`http://lidarr:8686`** (Full Sync)
- Prowlarr → proxy **`http://flaresolverr:8191/`**

UIs no browser usam o IP do host (`http://SEU_IP:8686`, etc.). Só a comunicação **container ↔ container** usa os hostnames da bridge.

---

## Plex e app mobile

1. `music-plex` usa **`network_mode: host`** (não aparece na bridge `music-server`).
2. Defina `PLEX_ADVERTISE_IP=http://IP_DA_LAN:32400/` no `.env` e recrie:
   ```bash
   docker compose up -d --force-recreate plex
   ```
3. Celular na **mesma Wi‑Fi**; force-close do app se ainda mostrar offline.
4. Logs esperados / inofensivos: `Server already claimed`, `libusb_init failed`, `Docker is used for versioning skip update check`.

Bibliotecas apontam para paths do host, ex.: `/media/music/Musicas/Artistas`, `/media/music/Fotos`.

---

## Volumes e dados

| Host | Container | Serviços |
|------|-----------|----------|
| `$LIDARR_CONFIG_DIR` | `/config` | Lidarr |
| `$PROWLARR_CONFIG_DIR` | `/config` | Prowlarr |
| `$QBITTORRENT_CONFIG_DIR` | `/config` | qBittorrent (`…/qBittorrent/qBittorrent.conf`) |
| `$PLEX_CONFIG_DIR` | `/config` | Plex |
| `$MOUNT_POINT` | mesmo path | Lidarr, qBit, Plex (Plex em `:ro`) |

`docker compose down` **não apaga** esses binds. Purge só com `sudo msi-uninstall --purge-data` (cuidado).

---

## Troubleshooting

**`docker compose`: command not found**  
Instale o plugin (`docker-compose-v2`) ou rode `sudo msi-install` / `ensure_docker` via update.

**Porta em uso**  
```bash
docker compose ps
ss -tlnp | grep -E '8686|9696|8080|32400|8191'
# units systemd legado:
sudo systemctl stop lidarr prowlarr flaresolverr plexmediaserver
sudo systemctl stop "qbittorrent-nox@$USER"
```

**App Plex offline na LAN**  
Confirme `network_mode: host`, `PLEX_ADVERTISE_IP`, e UDP `32410–32414`:
```bash
docker inspect music-plex --format '{{.HostConfig.NetworkMode}}'
ss -ulnp | grep 3241
curl -sS http://127.0.0.1:32400/identity
```

**Lidarr não fala com qBit**  
```bash
sudo msi-setup-media --qbit-password 'SENHA'
docker compose logs --tail 50 lidarr qbittorrent
```

**Ver health**  
```bash
docker compose ps
curl -sS http://127.0.0.1:8686/ping
curl -sS http://127.0.0.1:9696/ping
curl -sS http://127.0.0.1:8191/
```

---

## O que permanece fora do Compose

No **host** (não em container):

- Montagem do HD (`msi-mount`, fstab)
- OpenSSH / SFTP (FolderSync)
- UFW
- Fail2Ban, unattended-upgrades
- Timers restic / rclone (`msi-setup-security`, `msi-setup-cloud-backup`)

---

## Referências

- [ADR-0001](adrs/ADR-0001-migracao-systemd-para-docker.md)
- [docker-versioning.md](docker-versioning.md)
- [how-to.md](how-to.md) — fluxo Lidarr → Plex
- [plex-photos.md](plex-photos.md) — fotos + Docker
- README — tabela `msi-*`
