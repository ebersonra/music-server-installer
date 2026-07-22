# How-to: FolderSync no celular (fotos → Plex)

Guia para sincronizar fotos do Android para o HD externo do servidor via **SFTP**, para o **Plex Photos** indexar.

Paths reais:

```text
/media/music/Fotos
/media/music/Musicas
```

```text
Celular (DCIM, WhatsApp, …)
        │
        ▼
   FolderSync
        │  SFTP
        ▼
   Notebook Ubuntu
        │
        ▼
   /media/music/Fotos/...
        │
        ▼
   Plex (biblioteca Photos)
```

## Pré-requisitos

1. Servidor instalado com `sudo ./install.sh` (pastas de fotos + OpenSSH).
2. Celular e notebook na **mesma Wi‑Fi**.
3. App **FolderSync** (ou FolderSync Pro) na Play Store.
4. IP do servidor — no notebook:

```bash
hostname -I | awk '{print $1}'
```

5. Confirme as pastas:

```bash
ls -la /media/music/Fotos
grep PHOTOS_ROOT /var/lib/music-server-installer/install.state
```

---

## 1. Testar o SFTP antes (opcional)

No notebook, confirme que o SSH está ativo:

```bash
systemctl is-active ssh || systemctl is-active sshd
```

De outro PC ou do próprio celular (app de terminal), teste:

```text
sftp SEU_USUARIO@SEU_IP
```

Use o **usuário Linux** da instalação (não root) e a senha desse usuário.

---

## 2. Instalar o FolderSync

1. Abra a Play Store → busque **FolderSync**.
2. Instale (versão free basta para começar).
3. Abra o app e aceite as permissões de **arquivos / armazenamento** e, se pedir, **execução em segundo plano**.

---

## 3. Criar a conta SFTP

No FolderSync:

1. Toque em **Accounts** (Contas) → **+** (Add account).
2. Escolha **SFTP**.
3. Preencha:

| Campo            | Valor                                      |
|------------------|--------------------------------------------|
| **Name**         | `Servidor fotos` (qualquer nome)           |
| **Type**         | SFTP                                       |
| **Server**       | IP do notebook (ex.: `192.168.0.19`)        |
| **Port**         | `22`                                       |
| **Login type**   | Username/password                          |
| **Username**     | seu usuário Linux                          |
| **Password**     | senha desse usuário                        |
| **Directory**    | `/media/music/Fotos`                       |

4. Em opções avançadas (se houver):
   - **Connection timeout**: 30–60 s.
5. Toque em **Test** / **Validate** → deve conectar.
6. Salve.

### Dica: IP fixo

Se o IP do notebook muda com frequência, reserve um IP estático no roteador (DHCP reservation).

---

## 4. Criar os folder pairs (sincronizações)

Crie **um pair por pasta** do celular. Recomendado: sync **só celular → servidor** (upload / one-way).

### 4.1 Câmera → Camera

1. **Folder pairs** → **+**
2. **Account**: a conta SFTP criada
3. **Local folder**: `DCIM/Camera` (ou `DCIM` se preferir tudo da câmera)
4. **Remote folder**: `/media/music/Fotos/Camera`
5. **Sync type**: **To remote folder** (só envia; não apaga nada do celular ao espelhar)
6. **Scheduling**:
   - Ative sync automático
   - Intervalo: a cada **15–60 minutos**, ou **quando conectar ao Wi‑Fi**
7. Opções úteis:
   - **Sync subfolders**: sim
   - **Delete source after sync**: **não**
   - **Overwrite old files**: off no início
8. Salve → **Sync** uma vez manualmente para testar.

### 4.2 WhatsApp → WhatsApp

| Campo           | Valor                                                                 |
|-----------------|-----------------------------------------------------------------------|
| Local folder    | `Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images` (Android 11+) ou `WhatsApp/Media/WhatsApp Images` |
| Remote folder   | `/media/music/Fotos/WhatsApp`                                         |
| Sync type       | To remote folder                                                      |

Se não achar a pasta: no gerenciador de arquivos do celular, localize as imagens do WhatsApp e use **Use this folder**.

### 4.3 Screenshots → Screenshots

| Campo           | Valor                          |
|-----------------|--------------------------------|
| Local folder    | `Pictures/Screenshots` (ou `DCIM/Screenshots`) |
| Remote folder   | `/media/music/Fotos/Screenshots` |
| Sync type       | To remote folder               |

### Resumo sugerido

| No celular              | No servidor                         |
|-------------------------|-------------------------------------|
| `DCIM/Camera`           | `/media/music/Fotos/Camera`         |
| WhatsApp Images         | `/media/music/Fotos/WhatsApp`       |
| `Pictures/Screenshots`  | `/media/music/Fotos/Screenshots`    |

Pastas extras (`Familia`, `Viagens`, `Backup`) você pode usar depois.

---

## 5. Agendamento e bateria (Android)

Para o sync rodar sozinho:

1. **Folder pairs** → abra o pair → **Scheduling** ligado.
2. Nas configurações do Android:
   - **Bateria** → FolderSync → **Sem restrições** / não otimizar
   - Permita **dados em segundo plano** (só Wi‑Fi, se possível)
3. No FolderSync, se existir **Sync only on Wi‑Fi**, ative.

---

## 6. Conferir no servidor e no Plex

No notebook:

```bash
ls -la /media/music/Fotos/Camera
```

No Plex (`http://IP:32400/web`):

1. Biblioteca tipo **Photos** apontando para `/media/music/Fotos`
2. Se as fotos não aparecerem: reticências da biblioteca → **Scan Library Files**

---

## 7. Problemas comuns

**Não conecta (timeout / connection refused)**  
- Mesma Wi‑Fi? IP correto?  
- `sudo systemctl status ssh` (ou `sshd`) no notebook  
- Firewall: `sudo ufw status | grep 22`

**Auth failed**  
- Usuário/senha do Linux (não a senha do Plex)  
- Teste: `ssh usuario@IP` de outro PC

**Pasta remota não existe**  
- Rode `sudo ./mount.sh` se o HD desmontou  
- Confira: `ls /media/music/Fotos`

**Sync ok, Plex vazio**  
- Biblioteca Photos criada? Caminho `/media/music/Fotos`?  
- Permissões: o usuário `plex` precisa ler o HD (grupo `media`)

**Android 11+ sem acesso à pasta do WhatsApp**  
- Use o seletor de pastas do sistema (SAF) e autorize o FolderSync  
- Ou sincronize a partir de `Pictures/`

**IP mudou depois do reboot do roteador**  
- Atualize o IP na conta SFTP do FolderSync  
- Ou fixe o IP do notebook no roteador

---

## 8. Checklist rápido

- [ ] OpenSSH ativo no notebook  
- [ ] Conta SFTP no FolderSync testa OK  
- [ ] Pair Camera → `/media/music/Fotos/Camera` (to remote)  
- [ ] Sync manual enviou pelo menos 1 foto  
- [ ] Arquivo aparece em `ls /media/music/Fotos/Camera`  
- [ ] Plex Photos aponta para `/media/music/Fotos` e fez scan  

Pronto: fotos novas no celular sobem sozinhas; o Plex indexa no HD externo.
