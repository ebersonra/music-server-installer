# How-to: baixar músicas com Lidarr + Prowlarr + qBittorrent + Plex

Guia prático para configurar o stack instalado pelo **Music Server Installer** e começar a baixar álbuns automaticamente.

## Visão geral

```
Prowlarr  →  encontra torrents/NZBs (indexadores)
    ↓
Lidarr    →  decide o que baixar (artista/álbum)
    ↓
qBittorrent → baixa o arquivo
    ↓
Lidarr    →  organiza em Artistas/
    ↓
Plex      →  toca a biblioteca
```

| Serviço     | URL                         | Função              |
|-------------|-----------------------------|---------------------|
| Prowlarr    | `http://SEU_IP:9696`        | Indexadores         |
| Lidarr      | `http://SEU_IP:8686`        | Biblioteca / busca  |
| qBittorrent | `http://SEU_IP:8080`        | Cliente torrent     |
| Plex        | `http://SEU_IP:32400/web`   | Player              |

Troque `SEU_IP` pelo IP da máquina (ex.: `192.168.0.19`).

### Pastas padrão do instalador

```
/media/music/Musicas/              ← biblioteca
├── Artistas/                      ← Lidarr grava aqui (root folder)
└── Downloads/                     ← qBittorrent baixa aqui
    └── Incomplete/
```

Confira o caminho real:

```bash
grep MUSIC_ROOT /var/lib/music-server-installer/install.state
# esperado: /media/music/Musicas
```

---

## 0. Acesso inicial (importante)

1. Se Lidarr/Prowlarr pedirem login e você ainda não criou usuário:

```bash
sudo ./fix-servarr-auth.sh
```

2. Abra cada serviço e em **Settings → General → Security** ative **Forms** e crie usuário/senha.
3. qBittorrent: usuário `admin` — senha temporária no journal:

```bash
journalctl -u qbittorrent-nox@$USER -n 30 --no-pager | grep -i senha
```

Defina uma senha permanente em **Ferramentas → Opções → Web UI**.

---

## 1. qBittorrent — cliente de download

1. Abra `http://SEU_IP:8080` e faça login.
2. **Ferramentas → Opções → Downloads**:
   - Pasta padrão de salvamento: `.../Musicas/Downloads`
   - Manter incompletos em: `.../Musicas/Downloads/Incomplete` (opcional)
3. **Conexão**: deixe a porta padrão (ou a que o instalador configurou).
4. Salve.

Não precisa criar categorias agora; o Lidarr pode criar a categoria `lidarr` sozinho.

---

## 2. Prowlarr — indexadores

1. Abra `http://SEU_IP:9696`.
2. **Settings → General**: confirme a porta `9696` e salve.
3. **Indexers → Add Indexer** (`+`):
   - Escolha indexadores públicos ou privados que você usa.
   - Teste cada um (**Test**) até ficar verde.
4. **Settings → Apps → Add Application → Lidarr**:
   - **Prowlarr Server**: `http://localhost:9696` (ou o IP da máquina)
   - **Lidarr Server**: `http://localhost:8686`
   - **API Key**: copie em Lidarr → **Settings → General → Security → API Key**
   - **Sync Level**: `Full Sync` (recomendado)
   - **Test** → **Save**

Com isso, os indexadores do Prowlarr passam a aparecer no Lidarr automaticamente.

> Dica: comece com 2–3 indexadores estáveis. Muitos indexadores ruins só geram falha de busca.

---

## 3. Lidarr — biblioteca e download

### 3.1 Root folder (onde as músicas ficam)

1. Abra `http://SEU_IP:8686`.
2. **Settings → Media Management → Root Folders → Add Root Folder**:
   - Caminho: `.../Musicas/Artistas`  
     (ex.: `/media/music/Musicas/Artistas`)
3. Em **Settings → Media Management**:
   - Ative **Rename Tracks** se quiser nomes padronizados.
   - Qualidade: comece com perfil **Any** ou **Lossless** (conforme preferência).

### 3.2 Download client (qBittorrent)

1. **Settings → Download Clients → + → qBittorrent**:
   - Host: `localhost` (ou `127.0.0.1`)
   - Port: `8080`
   - Username: `admin`
   - Password: a senha que você definiu
   - Category: `lidarr`
2. **Test** → deve ficar verde → **Save**.

### 3.3 Indexadores no Lidarr

Se o Prowlarr já sincronizou (**Apps**), os indexadores aparecem em  
**Settings → Indexers**. Confirme que estão habilitados.

Se não sincronizou, adicione manualmente ou refaça o passo 2.4 do Prowlarr.

### 3.4 Metadata

Em **Settings → Metadata**, deixe pelo menos um provedor ativo (ex.: **Lidarr** / MusicBrainz padrão) para capas e tags.

---

## 4. Baixar o primeiro álbum

1. No Lidarr, clique em **Add New** (ou **Library → Add New**).
2. Digite o nome do artista → selecione o correto.
3. Escolha o **Root Folder** (`Artistas`).
4. Monitor: `All Albums` (ou só o que quiser).
5. Clique em **Add Artist** (ou **Add + Search**).
6. Abra o artista → escolha um álbum → **Search** / **Interactive Search**.
7. Escolha um release e clique em **Download**.

Acompanhe:

| Onde ver | O quê |
|----------|--------|
| Lidarr → **Activity → Queue** | fila do Lidarr |
| qBittorrent | torrent baixando |
| Lidarr → **Activity → History** | importação concluída |
| Pasta `Artistas/` | arquivos organizados |

Quando o download termina, o Lidarr importa para `Artistas/Nome Do Artista/...`.

---

## 5. Plex — escutar

1. Abra `http://SEU_IP:32400/web`.
2. **Settings → Libraries → Add Library → Music**.
3. Pasta: `.../Musicas/Artistas` (a mesma do Lidarr).
4. Salve e aguarde o scan.
5. Após novos downloads: na biblioteca → **Scan Library Files**.

Opcional: em Lidarr, **Settings → Connect → + → Plex** para avisar o Plex quando um álbum for importado (precisa do token Plex).

---

## 6. Checklist rápido (se nada baixa)

1. **Prowlarr** — indexador com **Test** verde?
2. **Prowlarr → Apps → Lidarr** — sync OK?
3. **Lidarr → Download Clients** — qBittorrent com **Test** verde?
4. **Lidarr → Root Folder** — caminho existe e é gravável?
5. **qBittorrent** — pasta `Downloads` no disco de músicas?
6. Disco montado?

```bash
findmnt /media/music
ls -la /media/music/Musicas /media/music/Fotos
ls -la "$(grep -oP 'MUSIC_ROOT=\K.*' /var/lib/music-server-installer/install.state | tr -d "'")"
```

7. Serviços ativos?

```bash
systemctl status lidarr prowlarr 'qbittorrent-nox@*' plexmediaserver --no-pager
```

---

## 7. Fluxo do dia a dia

1. No Lidarr, adicione artistas que você curte.
2. Deixe **Monitor** ativo.
3. O Lidarr busca periodicamente (RSS) via Prowlarr.
4. Quando encontra um álbum faltando, manda para o qBittorrent.
5. Após baixar, organiza em `Artistas/` e o Plex atualiza.

Para um álbum pontual: **Add → Search / Interactive Search → Download**.

---

## 8. Boas práticas

- Prefira qualidade estável (ex.: FLAC ou MP3 320) e mantenha um perfil só.
- Não misture root folder do Lidarr com downloads incompletos.
- Faça backup de `/var/lib/lidarr` e `/var/lib/prowlarr` se personalizar muito.
- Respeite a legislação local e os termos dos indexadores/trackers.

---

## Referência rápida de portas

| Porta  | Serviço      |
|--------|--------------|
| `8080` | qBittorrent  |
| `8686` | Lidarr       |
| `9696` | Prowlarr     |
| `32400`| Plex         |

Scripts úteis no repositório:

```bash
sudo ./install.sh              # instalação
sudo ./fix-servarr-auth.sh    # liberar/corrigir login Lidarr/Prowlarr
sudo ./update.sh               # atualizar serviços
sudo ./uninstall.sh            # remover serviços (mantém músicas)
```
