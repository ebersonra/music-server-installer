# Backup compacto do HD → nuvem (rclone)

Cópia de segurança para Google Drive (ou Dropbox, OneDrive, etc.) com [rclone](https://rclone.org/).

**Não espelha arquivos soltos** — eles já estão no HD externo e, no caso das fotos, no Google Fotos. Em vez disso, sobe:

| Payload | O que vai para a nuvem | Quando usar |
|---------|------------------------|-------------|
| **restic** (padrão) | Repositório de snapshots criptografados | Histórico + dedupe + economia de espaço |
| **zip** | Arquivos `*.zip` datados | Arquivo único simples (mp3/jpg quase não comprimem) |

```text
HD externo
 /media/music/Musicas
 /media/music/Fotos
        │
        ├── backup-restic.sh  → snapshots locais (criptografados)
        │         │
        │         ▼
        └── backup-cloud.sh
              │
              ├─ payload=restic → sync do repo → remote:.../restic-repo/
              └─ payload=zip    → musicas-YYYYMMDD.zip / fotos-YYYYMMDD.zip
```

## Scripts

| Script | Função |
|--------|--------|
| `sudo ./setup-cloud-backup.sh` | Instala rclone, escolhe payload, agenda timer |
| `sudo ./backup-cloud.sh` | Executa o backup agora |
| `sudo ./backup-cloud.sh --dry-run` | Simula sem enviar |
| `sudo ./backup-cloud.sh --payload restic` | Força modo restic |
| `sudo ./backup-cloud.sh --payload zip` | Força modo zip |
| `sudo ./backup-cloud.sh --photos-only` | Só fotos (modo zip) |
| `sudo ./backup-cloud.sh --music-only` | Só músicas (modo zip) |

## Setup rápido

```bash
cd music-server-installer
sudo ./setup-cloud-backup.sh
```

O assistente:

1. Instala o **rclone**
2. Abre `rclone config` (login no Google Drive no navegador)
3. Escolhe o remote, a pasta e o **payload** (`restic` ou `zip`)
4. Salva `/var/lib/music-server-installer/cloud-backup.conf`
5. Ativa timer systemd diário (padrão: 03:00)

Se escolher **restic**, configure também o repositório:

```bash
sudo ./setup-security.sh --only-restic
```

Use um path **local** (ex.: `/mnt/backup/restic-repo` ou pasta no próprio HD) para o `backup-cloud.sh` espelhar o repo na nuvem.  
Se o repositório já for `rclone:gdrive:...`, o restic grava direto na nuvem — o cloud backup só garante o snapshot.

### Google Drive no `rclone config`

- Nome sugerido: `gdrive`
- Storage: **Google Drive**
- client_id / secret: Enter (defaults)
- scope: Full access (ou drive.file)
- Auto config: **y** (abre o browser)

Em servidor **sem interface gráfica**, responda **n** no auto config e siga as instruções de token headless do rclone.

## Payload restic (recomendado)

1. `backup-restic.sh` cria/atualiza o snapshot (se `RUN_RESTIC_FIRST=true`)
2. `rclone sync` envia o repositório local → `remote:music-server-backup/restic-repo/`

Na nuvem você guarda o **histórico criptografado**, não uma segunda cópia navegável das pastas. Restore:

```bash
sudo ./restore-restic.sh --list
sudo ./restore-restic.sh --target /tmp/restore-test
# repo local sumiu:
sudo ./restore-restic.sh --from-cloud --target /tmp/restore-test --photos-only
```

Detalhes: **[security.md](security.md)** (seção Restore).

Guarde a senha de `/var/lib/music-server-installer/restic.password` **fora do PC**.
## Payload zip

Gera `musicas-YYYYMMDD.zip` / `fotos-YYYYMMDD.zip`, sobe para `remote:.../zips/` e mantém as N versões mais recentes (`ZIP_KEEP_REMOTE`).

- Staging padrão: `/media/music/.music-server-zip-staging` (no HD, não no root)
- `ZIP_COMPRESSION=0` (store) — áudio/foto já comprimidos; recomprimir gasta CPU sem ganho

Biblioteca grande: o zip diário inteiro é pesado; prefira **restic**.

## Config

```bash
sudo nano /var/lib/music-server-installer/cloud-backup.conf
```

| Variável | Significado |
|----------|-------------|
| `BACKUP_PAYLOAD` | `restic` ou `zip` |
| `RCLONE_REMOTE` | Nome do remote (`gdrive`) |
| `RCLONE_PATH` | Pasta raiz na nuvem |
| `RUN_RESTIC_FIRST` | Rodar `backup-restic.sh` antes do upload |
| `RESTIC_CLOUD_SUBDIR` | Subpasta do repo na nuvem |
| `ZIP_KEEP_REMOTE` | Quantos zips datados manter na nuvem |
| `ZIP_COMPRESSION` | `0`–`9` (use `0` para mídia) |
| `BACKUP_SCHEDULE` | Horário do timer (`*-*-* 00:00:00` com janela noturna) |
| `BACKUP_WINDOW_ENABLED` | `true` = só sobe dentro da janela |
| `BACKUP_WINDOW_START` / `END` | Ex.: `00:00` / `06:00` |
| `BACKUP_MAX_DURATION` | Opcional (ex.: `6h`); vazio = até o fim da janela |
| `BACKUP_USER` | Dono do `~/.config/rclone/rclone.conf` |

## Upload parcial (madrugada)

Para bibliotecas grandes (~100+ GiB), o rclone sobe **só na janela** e **retoma** na noite seguinte (sync idempotente):

```text
00:00  timer dispara → backup-cloud.sh
       └── rclone --max-duration até 06:00
06:00  para (packs já enviados ficam no Drive)
00:00  (dia seguinte) continua do que faltou
```

Na config:

```bash
BACKUP_WINDOW_ENABLED=true
BACKUP_WINDOW_START="00:00"
BACKUP_WINDOW_END="06:00"
BACKUP_SCHEDULE="*-*-* 00:00:00"
```

Forçar fora da janela:

```bash
sudo ./backup-cloud.sh --ignore-window
```

## Agendamento

```bash
systemctl status music-server-cloud-backup.timer
systemctl list-timers music-server-cloud-backup.timer
journalctl -u music-server-cloud-backup.service -n 50 --no-pager
```

Rodar na hora:

```bash
sudo systemctl start music-server-cloud-backup.service
# ou:
sudo ./backup-cloud.sh --ignore-window
```

Desativar:

```bash
sudo systemctl disable --now music-server-cloud-backup.timer
```

## Logs

```text
/var/lib/music-server-installer/logs/backup-restic-repo-YYYYMMDD.log
/var/lib/music-server-installer/logs/backup-zip-musicas-YYYYMMDD.log
/var/lib/music-server-installer/logs/backup-zip-fotos-YYYYMMDD.log
```

## Espaço e cotas

- Google Drive gratuito: 15 GB (compartilhado com Gmail).
- **restic** reaproveita dados entre snapshots (só sobe o que mudou).
- **zip** envia o arquivo inteiro a cada execução — cuide da cota e de `ZIP_KEEP_REMOTE`.
- Biblioteca grande: Google One, Backblaze B2, Mega, OneDrive, etc.

## Problemas comuns

**Auth / token expirado**

```bash
sudo -u SEU_USUARIO rclone config reconnect "Google Drive:"
# ou, se o remote se chama gdrive:
sudo -u SEU_USUARIO rclone config reconnect gdrive:
```

**Permission denied em `/media/backup-restic`**  
O repo restic é `root:root` com pastas `700`. O script sobe o repo como **root** usando o `rclone.conf` do `BACKUP_USER`. Se ainda falhar, confira:

```bash
sudo ls -la /media/backup-restic
sudo ./backup-cloud.sh --dry-run --payload restic
```

**Repo restic no disco do sistema**  
Se `RESTIC_REPOSITORY` for `/media/backup-restic` (ou similar em `/`), o snapshot cresce no SSD do notebook — preferível path no HD externo, ex. `/media/music/.restic-repo`.

**HD desmontado**

```bash
sudo ./mount.sh
sudo ./backup-cloud.sh
```

**restic não configurado**

```bash
sudo ./setup-security.sh --only-restic
# ou temporariamente:
sudo ./backup-cloud.sh --payload zip
```

**Rate limit Google (`User rate limit exceeded`)**  
Na config, reduza transfers / tpslimit:

```bash
RCLONE_EXTRA_OPTS="--fast-list --checkers 4 --transfers 2 --tpslimit 5 --retries 5"
```

**Aviso `shared Google Drive client_id`**  
O client_id padrão do rclone será desativado em 2026. Crie o seu: https://rclone.org/drive/#making-your-own-client-id

**Dry-run ok, job real falha**  
Veja o log do dia e `journalctl -u music-server-cloud-backup.service`.
---

Camadas de segurança (Fail2Ban, updates, restic): **[security.md](security.md)**.
