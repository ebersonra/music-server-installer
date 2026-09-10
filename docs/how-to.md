# How-to: baixar músicas com Lidarr + Prowlarr + FlareSolverr + qBittorrent + Plex

Guia prático para o stack do **Music Server Installer** ([diagrama atual](arquitetura-musica.png); [arquitetura completa de referência](arquitetura-full.jpg)).

## Visão geral

```
Lidarr (pedir)  →  Prowlarr + FlareSolverr (encontrar)
       ↓
qBittorrent (baixar, com bloqueio de executáveis)
       ↓
Lidarr (organiza em Artistas/)
       ↓
Plex (ouvir)
```

| Serviço      | URL                              | Função                    |
|--------------|----------------------------------|---------------------------|
| Lidarr       | `http://SEU_IP:8686`             | Pedir / biblioteca        |
| Prowlarr     | `http://SEU_IP:9696`             | Indexadores               |
| FlareSolverr | `http://127.0.0.1:8191`          | Cloudflare/captcha (local)|
| qBittorrent  | `http://SEU_IP:8080`             | Downloads                 |
| Plex         | `http://SEU_IP:32400/web`        | Player                    |

Troque `SEU_IP` pelo IP da máquina (ex.: `192.168.0.19`).

> **Pedir = Lidarr.** Apps tipo Overseerr/Jellyseerr não pedem música — use **Add New** / busca no Lidarr.

### Pastas padrão

```
/media/music/Musicas/              ← biblioteca
├── Artistas/                      ← Lidarr grava aqui (root folder)
└── Downloads/                     ← qBittorrent baixa aqui
    └── Incomplete/
```

```bash
grep MUSIC_ROOT /var/lib/music-server-installer/install.state
# esperado: /media/music/Musicas
```

### Wiring automático

Após o `install.sh` (ou a qualquer momento):

```bash
sudo ./setup-media-stack.sh
# ou: sudo msi-setup-media
```

Isso configura (idempotente):

- Root folder `Artistas/` no Lidarr
- Download client qBittorrent no Lidarr
- App Lidarr no Prowlarr (Full Sync)
- Proxy FlareSolverr no Prowlarr
- Failed download handling + blocklist de nomes-isca
- Tamanho mínimo (~2 MB) nas quality definitions
- Exclusões de arquivos perigosos no qBittorrent

Se o Test do qBittorrent falhar por senha:

```bash
sudo ./setup-media-stack.sh --qbit-password 'SUA_SENHA'
```

---

## 0. Acesso inicial

1. Se Lidarr/Prowlarr pedirem login e você ainda não criou usuário:

```bash
sudo ./fix-servarr-auth.sh
```

2. Em cada serviço: **Settings → General → Security** → **Forms** + usuário/senha.
3. qBittorrent: usuário `admin` — senha temporária:

```bash
journalctl -u qbittorrent-nox@$USER -n 30 --no-pager | grep -i senha
```

---

## 1. Proteção de download

### qBittorrent — arquivos excluídos

O instalador ativa **Excluded file names** com wildcards para:

- **Windows:** `*.exe`, `*.scr`, `*.bat`, `*.cmd`, `*.msi`, `*.com`, `*.vbs`, `*.ps1`, `*.dll`, `*.sys`, `*.js`
- **Unix/Linux:** `*.sh`, `*.bash`, `*.zsh`, `*.csh`, `*.ksh`, `*.deb`, `*.rpm`, `*.pkg`, `*.snap`, `*.AppImage`, `*.run`, `*.bin`, `*.so`, `*.dylib`, `*.apk`

Áudio (`*.flac`, `*.mp3`, …), `*.cue`, `*.log`, capas **não** são bloqueados.

Limite: o filtro age pelo **nome do arquivo** no torrent (não detecta malware renomeado para `.flac`).

### Lidarr

- Failed / completed download handling (via `setup-media-stack.sh`)
- Release profile `MSI-blocklist-armadilhas` (ex.: BROADCAST, SODAPOP, …)
- `minSize` ≥ 2 MB nas quality definitions (reduz fakes minúsculos)

---

## 2. Prowlarr — indexadores (música)

1. Abra `http://SEU_IP:9696`.
2. Confirme o proxy **FlareSolverr** em **Settings → Indexers → Indexer Proxies** (ou rode `setup-media-stack.sh`).
3. **Indexers → Add Indexer**: use fontes de **música** (públicas ou privadas que você tenha conta). Evite indexadores só de filme/série (YTS, EZTV, etc.).
4. Em indexadores com Cloudflare, associe o proxy FlareSolverr.
5. **Settings → Apps → Lidarr** deve existir após o wiring (Full Sync).

> Comece com 2–3 indexadores estáveis.

---

## 3. Lidarr — pedir e baixar

### 3.1 Root folder e download client

Já criados pelo wiring. Confira:

- **Media Management → Root Folders:** `.../Musicas/Artistas`
- **Download Clients → qBittorrent:** `127.0.0.1:8080`, category `lidarr`

### 3.2 Pedir o primeiro álbum

1. **Add New** → artista → **Root Folder** `Artistas` → Monitor → **Add + Search**.
2. Acompanhe: Lidarr **Activity** → qBittorrent → pasta `Artistas/`.

---

## 4. Plex — escutar

1. `http://SEU_IP:32400/web`
2. **Libraries → Add Library → Music** → pasta `.../Musicas/Artistas`
3. Scan após novos downloads

Opcional: Lidarr **Connect → Plex** (token Plex).

---

## 5. Checklist (se nada baixa)

1. Indexador no Prowlarr com **Test** verde?
2. App Lidarr + proxy FlareSolverr no Prowlarr?
3. Download client qBittorrent no Lidarr com **Test** verde?
4. Root folder existe e é gravável?
5. Disco montado?

```bash
findmnt /media/music
systemctl status lidarr prowlarr flaresolverr 'qbittorrent-nox@*' plexmediaserver --no-pager
sudo ./setup-media-stack.sh -y
```

---

## 6. Boas práticas

- Prefira um perfil de qualidade (FLAC ou MP3 320).
- Não misture root folder com `Downloads/Incomplete`.
- Respeite a legislação local e os termos dos indexadores.

---

## Portas

| Porta   | Serviço      |
|---------|--------------|
| `8080`  | qBittorrent  |
| `8191`  | FlareSolverr (localhost) |
| `8686`  | Lidarr       |
| `9696`  | Prowlarr     |
| `32400` | Plex         |

```bash
sudo ./install.sh
sudo ./setup-media-stack.sh
sudo ./fix-servarr-auth.sh
sudo ./update.sh
sudo ./uninstall.sh
```
