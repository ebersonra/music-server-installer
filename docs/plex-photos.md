# Fotos no Plex (HD externo)

Mesmo fluxo das músicas: pastas no HD montado + biblioteca no Plex. Sem Docker.

Paths reais:

```text
/media/music/Musicas
/media/music/Fotos
```

```text
Celular
    │
    ▼
FolderSync (SFTP)
    │
    ▼
Ubuntu → HD externo → /media/music/Fotos
    │
    ▼
Plex (biblioteca Photos)
```

## O que o instalador faz

1. Cria no HD:
   ```text
   /media/music/Fotos/
   ├── Camera/
   ├── WhatsApp/
   ├── Screenshots/
   ├── Familia/
   ├── Viagens/
   └── Backup/
   ```
2. Garante **OpenSSH** para sync via SFTP
3. Documenta no hint do Plex as duas bibliotecas (Music + Photos)

## Configurar no Plex

1. Abra `http://IP:32400/web`
2. **Add Library** → tipo **Photos**
3. Nome: `Fotos`
4. Pasta: `/media/music/Fotos`

O Plex indexa fotos novas sozinho.

## Enviar fotos do celular

O *Camera Upload* do app Plex foi descontinuado. Use **FolderSync** (Android).

Guia completo passo a passo: **[foldersync.md](foldersync.md)**.

| Origem no celular     | Destino SFTP                    |
|-----------------------|---------------------------------|
| `DCIM/`               | `/media/music/Fotos/Camera`     |
| `Pictures/`           | `/media/music/Fotos/Screenshots`|
| WhatsApp Images       | `/media/music/Fotos/WhatsApp`   |

Conexão:

```text
sftp://IP_DO_NOTE
usuário: seu usuário Linux
pasta: /media/music/Fotos
```

## Estrutura no HD

```text
/media/music/              # ponto de montagem
├── Musicas/
│   ├── Artistas/
│   └── Downloads/
└── Fotos/
    ├── Camera/
    ├── WhatsApp/
    └── …
```

Desinstalar o Plex **não apaga** as fotos no HD.
