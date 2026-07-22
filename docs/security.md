# Segurança do servidor doméstico

Três camadas recomendadas quando o notebook guarda **fotos da família** e músicas:

| Camada | Ferramenta | Função |
|--------|------------|--------|
| Acesso | **Fail2Ban** | Bloqueia IPs que tentam forçar o SSH |
| Sistema | **unattended-upgrades** | Aplica patches de segurança sozinho |
| Dados | **restic** | Snapshots versionados **e criptografados** |

Complementa o backup na nuvem (`docs/cloud-backup.md`): o cloud backup sobe o **repositório restic** (ou zips); o restic em si gera os snapshots criptografados com histórico.

```text
Internet
   │
   ▼
SSH ──► Fail2Ban (ban após tentativas)
   │
Ubuntu ──► unattended-upgrades (security)
   │
HD /media/music
   │
   └── restic snapshots ──► (opcional) rclone sync do repo → nuvem
```

## Setup rápido

```bash
sudo ./setup-security.sh
```

Opções:

```bash
sudo ./setup-security.sh --only-fail2ban
sudo ./setup-security.sh --only-updates
sudo ./setup-security.sh --only-restic
```

## 1. Fail2Ban (SSH)

- Jail `sshd`: 5 falhas em 10 min → ban 1 h (aumenta até 24 h).
- Config: `/etc/fail2ban/jail.d/sshd-music-server.local`

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip IP   # se você se autobloquear
```

**Dica:** use chave SSH e desative login por senha quando estiver confortável (`PasswordAuthentication no` em `/etc/ssh/sshd_config`).

## 2. unattended-upgrades

- Só origem **security** (não instala upgrades de feature sozinho).
- **Não** reinicia sozinho (`Automatic-Reboot false`).
- Timers: `apt-daily.timer` / `apt-daily-upgrade.timer`

```bash
sudo unattended-upgrade --dry-run
cat /var/log/unattended-upgrades/unattended-upgrades.log | tail
```

Após update de kernel, reinicie quando puder:

```bash
sudo reboot
```

## 3. restic (snapshots criptografados)

### Conceito

Cada execução cria um **snapshot** do estado de:

- `/media/music/Musicas` (sem Downloads por padrão)
- `/media/music/Fotos`

Dados no repositório são criptografados com a senha em:

```text
/var/lib/music-server-installer/restic.password
```

**Guarde essa senha fora do PC.** Sem ela, não há restore.

### Repositório

Exemplos em `setup-security.sh`:

| Tipo | Exemplo |
|------|---------|
| Outro HD | `/mnt/backup/restic-repo` |
| Google Drive (rclone) | `rclone:gdrive:restic-music-server` |
| SFTP | `sftp:user@host:/backups/restic` |

Para `rclone:`, configure antes: `sudo ./setup-cloud-backup.sh`.

### Uso

```bash
sudo ./backup-restic.sh              # snapshot + retenção
sudo ./backup-restic.sh --dry-run
sudo ./backup-restic.sh --prune-only
```

Listar / restaurar:

```bash
# carregar env
set -a
source /var/lib/music-server-installer/restic-backup.conf
set +a
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

restic snapshots
restic restore latest --target /tmp/restore-test
# ou só fotos:
restic restore latest --target /tmp/restore-fotos --include /media/music/Fotos
```

Retenção padrão: 7 diários, 4 semanais, 6 mensais, 2 anuais.

Timer: `music-server-restic.timer` (padrão 04:00).

```bash
systemctl status music-server-restic.timer
journalctl -u music-server-restic.service -n 40 --no-pager
```

## Estratégia sugerida (família)

1. **restic** diário → disco local **e/ou** nuvem (`backup-cloud.sh --payload restic`)  
2. Fail2Ban + updates sempre ligados  
3. Notebook só na LAN; SSH só se precisar (ou VPN)  
4. Evite espelhar arquivos soltos na nuvem (já estão no HD / Google Fotos)

## Checklist

- [ ] `fail2ban-client status sshd` mostra jail ativa  
- [ ] `unattended-upgrade --dry-run` ok  
- [ ] Senha restic guardada offline  
- [ ] `sudo ./backup-restic.sh` criou o 1º snapshot  
- [ ] Teste de restore em `/tmp/restore-test`  
- [ ] HD montado (`findmnt /media/music`) antes dos jobs  

## Relação com rclone

| | rclone (`backup-cloud.sh`) | restic (`backup-restic.sh`) |
|--|---------------------------|------------------------------|
| Papel | Leva o **repo** (ou zips) à nuvem | Cria snapshots criptografados |
| Criptografia | Depende do payload (restic: sim) | Sim (nativa) |
| Versões | Via snapshots no repo / zips datados | Sim (snapshots) |
| Deduplicação | No repo restic | Forte |
| Navegar no Drive | Repo opaco / zips | Precisa `restic mount` / restore |

Para fotos da família, **restic + sync do repo na nuvem** é a rede de segurança; zip é alternativa simples.
