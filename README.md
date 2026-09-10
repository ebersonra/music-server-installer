# Music Server Installer

Instalador interativo em Bash para montar um servidor de músicas no **Ubuntu/Debian**, no estilo CasaOS/Umbrel.

Instala e configura:

| Serviço         | Porta   | Função                                      |
|-----------------|---------|---------------------------------------------|
| **Plex**        | `32400` | Músicas + fotos (HD externo)                |
| **Lidarr**      | `8686`  | Pedir / gerenciar artistas e álbuns         |
| **Prowlarr**    | `9696`  | Indexadores                                 |
| **FlareSolverr**| `8191`  | Bypass Cloudflare/captcha (só localhost)    |
| **qBittorrent** | `8080`  | Cliente de download (+ bloqueio de malware) |

Também detecta discos (incluindo NTFS/USB), cria pastas, ajusta permissões, abre portas no firewall e **liga** Lidarr ↔ Prowlarr ↔ qBit ↔ FlareSolverr via `setup-media-stack.sh`.

Fluxo (subset música — diagrama: [docs/arquitetura-musica.png](docs/arquitetura-musica.png); visão completa com vídeo: [docs/arquitetura-full.jpg](docs/arquitetura-full.jpg)):

```
Lidarr (pedir) → Prowlarr + FlareSolverr (encontrar)
    → qBittorrent (baixar) → Lidarr (organizar em Artistas/) → Plex (ouvir)
```

---

## Estrutura do projeto

```
music-server-installer/
├── install.sh              # Orquestrador interativo
├── mount.sh                # Só remonta o disco (sem reinstalar)
├── update.sh               # Atualiza serviços instalados
├── uninstall.sh            # Remove serviços (preserva músicas)
├── setup-media-stack.sh    # Wiring Lidarr/Prowlarr/qBit/FlareSolverr
├── setup-cloud-backup.sh   # Configura rclone + timer (restic/zip → nuvem)
├── backup-cloud.sh         # Backup compacto HD → nuvem (restic ou zip)
├── setup-security.sh       # Fail2Ban + updates + restic
├── backup-restic.sh        # Snapshots criptografados (restic)
├── restore-restic.sh       # Restore de snapshots (local ou nuvem)
├── link-global.sh          # Symlinks em /usr/local/bin (msi-*)
├── common.sh               # Funções compartilhadas / UI / discos
├── config.sh               # Variáveis e defaults
├── fix-servarr-auth.sh     # Corrige auth Lidarr/Prowlarr
├── reset-mount.sh          # Limpa mount fantasma do HD
├── README.md
│
├── services/
│   ├── plex.sh
│   ├── lidarr.sh
│   ├── prowlarr.sh
│   ├── qbittorrent.sh
│   ├── flaresolverr.sh
│   ├── mountdisk.sh        # NTFS / fstab / montagem
│   ├── firewall.sh
│   ├── permissions.sh
│   └── security.sh         # Fail2Ban / unattended-upgrades
│
├── docs/
│   ├── how-to.md           # Guia: baixar e organizar músicas
│   ├── arquitetura-musica.png  # Diagrama do stack atual (só música)
│   ├── arquitetura-full.jpg    # Referência: arquitetura completa (vídeo+música)
│   ├── plex-photos.md
│   ├── foldersync.md
│   ├── cloud-backup.md
│   └── security.md
│
└── templates/
    ├── lidarr.xml
    ├── qbittorrent.conf
    ├── cloud-backup.conf
    ├── restic-backup.conf
    ├── fail2ban-sshd.local
    └── systemd/
        ├── lidarr.service
        ├── prowlarr.service
        ├── qbittorrent-nox.service
        └── flaresolverr.service
```

O `install.sh` só orquestra: a lógica fica em `common.sh`, `config.sh` e `services/*.sh`.

---

## Requisitos

- Ubuntu 20.04+ ou Debian 11+
- Usuário com `sudo`
- Disco para a biblioteca (interno, USB ou NTFS)
- Rede local (para acessar as UIs)

---

## Instalação rápida

```bash
git clone https://github.com/ebersonra/music-server-installer.git
cd music-server-installer
sudo ./install.sh
```

### O que o instalador pergunta

1. Disco / partição (prioriza USB/externo)
2. Usuário do sistema
3. Nome da biblioteca Plex de músicas (padrão: `Músicas`)
4. Nome da biblioteca Plex de fotos (padrão: `Fotos`)
5. Quais serviços instalar

### O que faz em seguida

```
✓ Atualizando Ubuntu/Debian
✓ Instalando dependências
✓ Configurando NTFS / montagem
✓ Criando pastas
✓ Instalando Plex / qBittorrent / Lidarr / Prowlarr
✓ Permissões e firewall
✓ Exibindo URLs
```

Se um serviço falhar, a instalação **continua** e lista os erros no final.

### Pastas criadas

```
/media/music/Musicas/
├── Artistas/          # biblioteca do Lidarr / Plex
└── Downloads/         # qBittorrent
    └── Incomplete/

/media/music/Fotos/    # Plex Photos (mesmo HD)
├── Camera/
├── WhatsApp/
├── Screenshots/
├── Familia/
├── Viagens/
└── Backup/
```

Ponto de montagem padrão: `/media/music`.

Guia de fotos: **[docs/plex-photos.md](docs/plex-photos.md)**.  
FolderSync no celular: **[docs/foldersync.md](docs/foldersync.md)**.  
Backup do HD na nuvem: **[docs/cloud-backup.md](docs/cloud-backup.md)**.  
Segurança (Fail2Ban / updates / restic): **[docs/security.md](docs/security.md)**.

---

## Após instalar

Acesse (troque pelo IP da máquina):

```
Plex         http://IP:32400/web
Lidarr       http://IP:8686
Prowlarr     http://IP:9696
qBittorrent  http://IP:8080
FlareSolverr http://127.0.0.1:8191   # só na máquina
```

- **qBittorrent:** usuário `admin` — senha temporária no journal:
  ```bash
  journalctl -u qbittorrent-nox@$USER -n 30 --no-pager | grep -i senha
  ```
- **Lidarr / Prowlarr:** no 1º acesso, configure Forms + usuário em  
  **Settings → General → Security**.
- **Plex Photos:** adicione biblioteca tipo Photos apontando para `/media/music/Fotos`. Sync do celular: [docs/foldersync.md](docs/foldersync.md).

O instalador já tenta ligar root folder, download client e proxy FlareSolverr. Se precisar refazer:

```bash
sudo ./setup-media-stack.sh
# ou: sudo msi-setup-media
```

Guia completo: **[docs/how-to.md](docs/how-to.md)**.

Ouvir no celular: app **Plex** na mesma conta, na Wi‑Fi do servidor.

---

## Comandos globais (`msi-*`)

O repositório é a **fonte da verdade**. `link-global.sh` cria symlinks em `/usr/local/bin` — edições nos `.sh` do projeto valem na hora, sem recopiar.

```bash
cd /caminho/para/music-server-installer
sudo ./link-global.sh          # cria/atualiza links
./link-global.sh --list        # ver mapeamento
sudo ./link-global.sh --remove # remove links deste repo
```

Depois, em **qualquer terminal** (sem `cd` no projeto):

| Comando global | Equivalente no repo |
|----------------|---------------------|
| `sudo msi-install` | `./install.sh` |
| `sudo msi-mount` | `./mount.sh` |
| `sudo msi-update` | `./update.sh` |
| `sudo msi-uninstall` | `./uninstall.sh` |
| `sudo msi-setup-media` | `./setup-media-stack.sh` |
| `sudo msi-setup-cloud-backup` | `./setup-cloud-backup.sh` |
| `sudo msi-backup-cloud` | `./backup-cloud.sh` |
| `sudo msi-setup-security` | `./setup-security.sh` |
| `sudo msi-backup-restic` | `./backup-restic.sh` |
| `sudo msi-restore-restic` | `./restore-restic.sh` |
| `sudo msi-fix-servarr-auth` | `./fix-servarr-auth.sh` |
| `sudo msi-reset-mount` | `./reset-mount.sh` |
| `msi-link-global --list` | `./link-global.sh --list` |

Se mover o clone do projeto, rode de novo `sudo ./link-global.sh` (ou `sudo msi-link-global`) para apontar os links ao novo caminho.

---

## Scripts auxiliares

| Script | Uso |
|--------|-----|
| `sudo ./install.sh` | Instalação interativa |
| `sudo ./mount.sh` | **Só remonta o disco** (após reboot / HD replugado) |
| `sudo ./update.sh` | Atualiza serviços |
| `sudo ./uninstall.sh` | Remove serviços (músicas/fotos preservadas) |
| `sudo ./uninstall.sh --purge-data` | Remove também configs dos apps |
| `sudo ./setup-media-stack.sh` | Liga Lidarr/Prowlarr/qBit/FlareSolverr (idempotente) |
| `sudo ./setup-cloud-backup.sh` | Configura backup compacto HD → nuvem (rclone) |
| `sudo ./backup-cloud.sh` | Envia restic (snapshots) ou *.zip para a nuvem |
| `sudo ./setup-security.sh` | Fail2Ban + updates automáticos + restic |
| `sudo ./backup-restic.sh` | Snapshot criptografado (restic) |
| `sudo ./restore-restic.sh` | Restaura snapshots restic (local ou nuvem) |
| `sudo ./fix-servarr-auth.sh` | Corrige login/HTTP 500 do Lidarr/Prowlarr |
| `sudo ./reset-mount.sh` | Desmonta mount fantasma (ex.: `/media/music`) |
| `sudo ./link-global.sh` | Publica os scripts como `msi-*` no PATH |

Opções do instalador:

```bash
sudo ./install.sh -y                 # confirma automático
sudo ./install.sh --skip-system-update
sudo ./install.sh -h
```

---

## Solução rápida de problemas

**HD NTFS / USB não aparece**  
O instalador detecta via `lsblk` + `blkid`/`udevadm`. Se falhar, use a opção `[m]` e informe `/dev/sdX1`.

**HD desmontou após reboot / letra mudou (`sdb` → `sdc`)**  
```bash
sudo ./mount.sh          # remonta usando o estado salvo
sudo ./mount.sh -i       # escolher disco de novo
```
Mount fantasma / FUSE morto (`Ponto final de transporte não está conectado`):
```bash
sudo ./reset-mount.sh
# reconecte o cabo USB se necessário
sudo ./mount.sh
```
Prefira montar em `/media/music` (paths: `/media/music/Musicas`, `/media/music/Fotos`).

**Lidarr/Prowlarr com HTTP 500 (DryIoc / auth)**  
```bash
sudo ./fix-servarr-auth.sh
```
Causa comum: valor inválido em `AuthenticationRequired` (use `DisabledForLocalAddresses`, não `Disabled`).

**Torrents parados / 0 peers**  
Veja fila no qBittorrent (itens “Parado” ou magnet com 0 B), ative DHT/PeX/UPnP e aumente downloads ativos. Detalhes em [docs/how-to.md](docs/how-to.md).

---

## Estado da instalação

Arquivos gravados em:

```
/var/lib/music-server-installer/install.state
```

Usado por `update.sh` e `uninstall.sh`.

---

## Licença

Uso livre para fins pessoais. Respeite a legislação local e os termos dos serviços/indexadores que você configurar.
