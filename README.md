# nix-config — Mauricio's home-lab

Fork mínimo de [`notthebee/nix-config`](https://git.notthebee.ee/notthebee/nix-config), adaptado al `home-server`.

## Hosts

| Host | Rol | Estado |
|---|---|---|
| `home-server` | Servidor casa (i5-4440, 8 GB, SSD 223 GB + HDD 931 GB) | Fase A completa |

## Layout

- `modules/machines/nixos/_common/` — defaults (SSH, firewall, nix, fail2ban).
- `modules/machines/nixos/home-server/` — config del host (disko, hardware, red).
- `modules/misc/{tailscale,agenix,zfs-root}/` — módulos auxiliares.
- `modules/homelab/` — catálogo de servicios upstream (no importado en Fase A).
- `users/mauri/` — usuario + home-manager.
- `secrets/secrets.nix` — mapa pubkey → archivo `.age`. Contenidos en repo privado `nix-private`.
- `bin/smoke-test.sh` — verificación post-install.
- `justfile` — recetas (check, deploy, rollback).

## Operar

### Deploy (en home-server)
```bash
just deploy         # nixos-rebuild switch --flake .#home-server
just rollback       # vuelve a generación previa
```

### Editar secreto (desde cualquier host con agenix + pubkey autorizada)
```bash
cd nix-private
agenix -e secrets/tailscale-authkey.age
```

### Smoke test (desde cualquier host con SSH a home-server)
```bash
just smoke
```

## Secretos

Tres secretos en Fase A, todos en `nix-private`:

| Archivo | Montado | Consumidor |
|---|---|---|
| `tailscale-authkey.age` | `/run/agenix/tailscaleAuthKey` | `services.tailscale` |
| `mauri-hashed-password.age` | `/run/agenix/mauri-password` | `users.users.mauri.hashedPasswordFile` |
| `hello-secret.age` | `/run/agenix/hello-secret` | smoke-test |

## Fases

- **A** (esta) — Fundamento: NixOS instalado, SSH/Tailscale/ZFS/agenix/rollback verdes.
- **B** — Reverse proxy + dominio público.
- **C** — Servicios (Samba/NFS, media, etc.).
- **D** — SSO, multi-tenant, migración de `nix-private` a Forgejo.
