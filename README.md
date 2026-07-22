# Music Server Installer

Instalador interativo em Bash para montar um servidor de músicas no **Ubuntu/Debian**, no estilo CasaOS/Umbrel.

Instala e configura:

| Serviço      | Porta  | Função                          |
|--------------|--------|---------------------------------|
| **Plex**     | `32400`| Músicas + fotos (HD externo)    |
| **Lidarr**   | `8686` | Gerência de artistas/álbuns     |
| **Prowlarr** | `9696` | Indexadores                     |
| **qBittorrent** | `8080` | Cliente de download          |

Também detecta discos (incluindo NTFS/USB), cria pastas, ajusta permissões e abre portas no firewall.

---

## Estrutura do projeto

```
music-server-installer/
├── install.sh              # Orquestrador interativo
├── mount.sh                # Só remonta o disco (sem reinstalar)
├── update.sh               # Atualiza serviços instalados
├── uninstall.sh            # Remove serviços (preserva músicas)
├── setup-cloud-backup.sh   # Configura rclone + timer (restic/zip → nuvem)
├── backup-cloud.sh         # Backup compacto HD → nuvem (restic ou zip)
├── setup-security.sh       # Fail2Ban + updates + restic
├── backup-restic.sh        # Snapshots criptografados (restic)
├── restore-restic.sh       # Restore de snapshots (local ou nuvem)
├── common.sh               # Funções compartilhadas / UI / discos
├── config.sh               # Variáveis e defaults
├── fix-servarr-auth.sh     # Corrige auth Lidarr/Prowlarr
├── reset-mount.sh          # Limpa mount fantasma do HD
├── how-to.md               # Guia: baixar e organizar músicas
├── README.md
│
├── services/
│   ├── plex.sh
│   ├── lidarr.sh
│   ├── prowlarr.sh
│   ├── qbittorrent.sh
│   ├── mountdisk.sh        # NTFS / fstab / montagem
│   ├── firewall.sh
│   ├── permissions.sh
│   └── security.sh         # Fail2Ban / unattended-upgrades
│
├── docs/
│   ├── plex-photos.md      # Guia Plex Photos
│   ├── foldersync.md       # How-to FolderSync no celular
│   ├── cloud-backup.md     # Backup HD → Google Drive / nuvem
│   └── security.md         # Fail2Ban, updates, restic
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
        └── qbittorrent-nox.service
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
```

- **qBittorrent:** usuário `admin` — senha temporária no journal:
  ```bash
  journalctl -u qbittorrent-nox@$USER -n 30 --no-pager | grep -i senha
  ```
- **Lidarr / Prowlarr:** no 1º acesso, configure Forms + usuário em  
  **Settings → General → Security**.
- **Plex Photos:** adicione biblioteca tipo Photos apontando para `/media/music/Fotos`. Sync do celular: [docs/foldersync.md](docs/foldersync.md).

Guia completo de configuração e downloads: **[how-to.md](how-to.md)**.

Ouvir no celular: app **Plex** na mesma conta, na Wi‑Fi do servidor.

---

## Scripts auxiliares

| Script | Uso |
|--------|-----|
| `sudo ./install.sh` | Instalação interativa |
| `sudo ./mount.sh` | **Só remonta o disco** (após reboot / HD replugado) |
| `sudo ./update.sh` | Atualiza serviços |
| `sudo ./uninstall.sh` | Remove serviços (músicas/fotos preservadas) |
| `sudo ./uninstall.sh --purge-data` | Remove também configs dos apps |
| `sudo ./setup-cloud-backup.sh` | Configura backup compacto HD → nuvem (rclone) |
| `sudo ./backup-cloud.sh` | Envia restic (snapshots) ou *.zip para a nuvem |
| `sudo ./setup-security.sh` | Fail2Ban + updates automáticos + restic |
| `sudo ./backup-restic.sh` | Snapshot criptografado (restic) |
| `sudo ./restore-restic.sh` | Restaura snapshots restic (local ou nuvem) |
| `sudo ./fix-servarr-auth.sh` | Corrige login/HTTP 500 do Lidarr/Prowlarr |
| `sudo ./reset-mount.sh` | Desmonta mount fantasma (ex.: `/media/music`) |

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
Mount fantasma antigo:
```bash
sudo ./reset-mount.sh
sudo ./mount.sh
```
Prefira montar em `/media/music` (paths: `/media/music/Musicas`, `/media/music/Fotos`).

**Lidarr/Prowlarr com HTTP 500 (DryIoc / auth)**  
```bash
sudo ./fix-servarr-auth.sh
```
Causa comum: valor inválido em `AuthenticationRequired` (use `DisabledForLocalAddresses`, não `Disabled`).

**Torrents parados / 0 peers**  
Veja fila no qBittorrent (itens “Parado” ou magnet com 0 B), ative DHT/PeX/UPnP e aumente downloads ativos. Detalhes em [how-to.md](how-to.md).

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
