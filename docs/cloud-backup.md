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
set -a
source /var/lib/music-server-installer/restic-backup.conf
set +a
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

# Se restaurou o repo da nuvem para um path local:
# export RESTIC_REPOSITORY=/caminho/do/repo

restic snapshots
restic restore latest --target /tmp/restore-test
```

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
| `BACKUP_SCHEDULE` | Horário do timer |
| `BACKUP_USER` | Dono do `~/.config/rclone/rclone.conf` |

## Agendamento

```bash
systemctl status music-server-cloud-backup.timer
systemctl list-timers music-server-cloud-backup.timer
journalctl -u music-server-cloud-backup.service -n 50 --no-pager
```

Rodar na hora:

```bash
sudo systemctl start music-server-cloud-backup.service
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
sudo -u SEU_USUARIO rclone config reconnect gdrive:
```

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

**Dry-run ok, job real falha**  
Veja o log do dia e `journalctl -u music-server-cloud-backup.service`.

---

Camadas de segurança (Fail2Ban, updates, restic): **[security.md](security.md)**.
