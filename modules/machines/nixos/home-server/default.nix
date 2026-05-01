{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../_common
    ../../../misc/zfs-root
    ../../../misc/tailscale
    ../../../misc/agenix
    ../../../misc/cloudflared
    ../../../misc/fail2ban-jails
    ../../../misc/tailscale-serve
    ../../../misc/zfs-services-bootstrap
    ../../../services/whoami
    ../../../services/vaultwarden
    ../../../services/uptime-kuma
    ../../../services/homepage
    ../../../services/samba
    # E.1 — apps stack (postgres compartido + gestión documental + CalDAV/CardDAV)
    ../../../services/postgres-shared
    ../../../services/paperless
    ../../../services/radicale
    # E.3 — observabilidad (prometheus + grafana + exporters)
    ../../../services/prometheus-homelab
    ../../../services/grafana-homelab
    # E.2 — media stack (Jellyfin primero; *arr/deluge/jellyseerr en sub-deploys)
    ../../../services/jellyfin-homelab
    ../../../services/deluge-homelab
    ../../../services/arr-stack-homelab
    ../../../services/jellyseerr-homelab
    # D.3 — SSO (Keycloak Quarkus, postgres-shared backend, dataset encriptado)
    ../../../services/keycloak-homelab
    ../../../../users/mauri
    ./hardware.nix
    ./disko.nix
  ];

  # Auto-create datasets E.1 si faltan (defensa contra disaster recovery + dev re-deploy).
  # Lección aprendida 2026-04-25: disko solo crea datasets en install fresco; para sumar
  # datasets en host ya instalado, sin este módulo el deploy falla con emergency mode.
  services.zfs-services-bootstrap = {
    enable = true;
    datasets = {
      "rpool/services/postgres-shared" = { recordsize = "8K"; };
      "rpool/services/paperless"       = { };
      "rpool/services/radicale"        = { };
      "tank/docs"                      = { recordsize = "1M"; };
      # E.3 — observabilidad
      "rpool/services/prometheus"      = { };
      "rpool/services/grafana"         = { };
      # E.2a — media (Jellyfin)
      "rpool/services/jellyfin"        = { };
      "rpool/services/jellyfin-cache"  = { };
      "tank/storage/media/movies"      = { recordsize = "1M"; };
      "tank/storage/media/tv"          = { recordsize = "1M"; };
      "tank/storage/media/music"       = { recordsize = "1M"; };
      # E.2b — Deluge
      "rpool/services/deluge"          = { };
      "tank/downloads"                 = { recordsize = "1M"; };
      # E.2c — *arr stack (sin prowlarr — DynamicUser=yes, vive en rpool/var)
      "rpool/services/sonarr"          = { };
      "rpool/services/radarr"          = { };
      "rpool/services/bazarr"          = { };
      # E.2d — Jellyseerr DynamicUser=yes → vive en rpool/var (sin dataset propio)
      # D.3 — Keycloak con ZFS native encryption (key en agenix)
      "rpool/services/keycloak" = {
        encrypted = true;
        encryptionKeyPath = config.age.secrets.keycloakZfsKey.path;
        extraProperties = {
          compression = "zstd-3";
        };
      };
    };
    beforeMounts = [
      "var-lib-postgresql.mount"
      "var-lib-paperless.mount"
      "var-lib-radicale.mount"
      "srv-docs.mount"
      # E.3
      "var-lib-prometheus2.mount"
      "var-lib-grafana.mount"
      # E.2a
      "var-lib-jellyfin.mount"
      "var-cache-jellyfin.mount"
      "srv-storage-media-movies.mount"
      "srv-storage-media-tv.mount"
      "srv-storage-media-music.mount"
      # E.2b
      "var-lib-deluge.mount"
      "srv-downloads.mount"
      # E.2c (prowlarr no — DynamicUser, sin dataset)
      "var-lib-sonarr.mount"
      "var-lib-radarr.mount"
      "var-lib-bazarr.mount"
      # D.3 — Keycloak (encrypted dataset, requiere load-key pre-mount)
      "var-lib-keycloak.mount"
    ];
  };

  # Fase B — Cloudflare Tunnel activo. Credenciales en agenix cloudflared-credentials.age.
  services.cloudflared-homelab = {
    enable = true;
    tunnelId = "f97802ac-24f1-4810-8042-3d207292eb78";
    ingress = {
      "whoami.mauricioantolin.com" = "http://127.0.0.1:8080";
      "vault.mauricioantolin.com" = "http://127.0.0.1:8222";
      # E.1
      "paperless.mauricioantolin.com" = "http://127.0.0.1:8000";
      "cal.mauricioantolin.com" = "http://127.0.0.1:5232";
      # E.2d — Jellyseerr UI pública (auth interna via Jellyfin)
      "requests.mauricioantolin.com" = "http://127.0.0.1:5055";
      # D.3 — Keycloak SSO (hostname-strict=true exige Host: auth.mauricioantolin.com,
      # por eso NO va por tailscale-serve con magic hostname).
      "auth.mauricioantolin.com" = "http://127.0.0.1:8180";
    };
  };

  # Vaultwarden público vía CF Tunnel. Bootstrap con signups=true por una iteración,
  # después flip a false (Task 3.7).
  services.vaultwarden-homelab = {
    enable = true;
    domain = "vault.mauricioantolin.com";
    allowSignups = false; # cerrado tras bootstrap
  };

  services.fail2ban-jails-homelab = {
    enable = true;
    cfZone = "mauricioantolin.com";
    blockMode = "block";
    jails.vaultwarden = {
      service = "vaultwarden";
      backend = "cloudflare";
      failregex = ''
        ^.*Username or password is incorrect\. Try again\. IP: <HOST>\. Username:.*$
        ^.*Invalid admin token\. IP: <HOST>\.$
      '';
      maxRetry = 5;
      findTime = "10m";
      banTime = "4h";
    };
    jails.samba = {
      service = "samba-smbd";
      backend = "nftables";
      failregex = ''
        ^.*Auth:.*status \[NT_STATUS_(WRONG_PASSWORD|NO_SUCH_USER|LOGON_FAILURE)\].*remote host \[ipv4:<HOST>:[0-9]+\].*$
        ^.*Auth:.*status \[NT_STATUS_(WRONG_PASSWORD|NO_SUCH_USER|LOGON_FAILURE)\].*remote host \[ipv6:<HOST>:[0-9]+\].*$
      '';
      ignoreIp = [ "127.0.0.1/8" "::1" "100.64.0.0/10" ];
      maxRetry = 5;
      findTime = "10m";
      banTime = "1h";
    };
    # E.1 hardening — paperless está atrás de CF Tunnel + Access OTP, con lo que
    # bruteforce vía CF requiere haber pasado OTP primero. Defense-in-depth: si
    # alguien obtiene cookie Access pero falla login VW/paperless, lo banean.
    # Solo matchea cuando paperless logea IP via X-Forwarded-For (CF→cloudflared→paperless).
    # NO se incluye radicale: radicale no parsea CF-Connecting-IP, ve siempre 127.0.0.1
    # detrás del tunnel; fail2ban quedaría inútil (banearía loopback).
    jails.paperless = {
      service = "paperless-web";
      backend = "cloudflare";   # paperless es público vía CF; ban en CF edge
      failregex = ''
        ^.*\[paperless\.auth\] Login failed for user `[^`]+` from <HOST>\.\s*$
      '';
      ignoreIp = [ "127.0.0.1/8" "::1" "100.64.0.0/10" ];
      maxRetry = 5;
      findTime = "10m";
      banTime = "1h";
    };
  };

  services.uptime-kuma-homelab.enable = true;

  services.homepage-homelab.enable = true;

  services.tailscale-serve-homelab = {
    enable = true;
    magicHostname = "home-server.tailee5654.ts.net";
    handlers = {
      # Homepage en :443/ (default)
      homepage = { Proxy = "http://127.0.0.1:3000"; };
      # Uptime Kuma en puerto dedicado :8443 (su frontend rompe bajo subpath:
      # redirige a /dashboard absoluto. Plan B documentado en spec C.1).
      uptime = { Proxy = "http://127.0.0.1:3001"; Port = 8443; };
      # E.3 — Grafana en :3443/ (root path, puerto dedicado).
      # Subpath /grafana/ producía redirect loop con TLS-termination de Tailscale
      # Serve. Mismo patrón Plan-B que Kuma. URL: https://...:3443/.
      grafana = { Proxy = "http://127.0.0.1:3030"; Port = 3443; };
      # E.3 — Prometheus en :9443/ (uso interno; rara vez se accede directo,
      # pero útil para debug de scrape targets sin SSH).
      prometheus = { Proxy = "http://127.0.0.1:9090"; Port = 9443; };
      # E.2 — Tailscale Serve binds en la IP del nodo en el tailnet (ej: 100.65.79.114).
      # Si los servicios bindean 0.0.0.0:<puerto> (jellyfin, *arr), colisionan con
      # ese mismo puerto en la IP tailnet. Solución: external port distinto del backend.
      # Patrón: external = backend + 100.
      jellyfin = { Proxy = "http://127.0.0.1:8096"; Port = 8196; };
      deluge   = { Proxy = "http://127.0.0.1:8112"; Port = 8212; };
      sonarr   = { Proxy = "http://127.0.0.1:8989"; Port = 9089; };
      radarr   = { Proxy = "http://127.0.0.1:7878"; Port = 7978; };
      prowlarr = { Proxy = "http://127.0.0.1:9696"; Port = 9796; };
      bazarr   = { Proxy = "http://127.0.0.1:6767"; Port = 6867; };
    };
  };

  services.samba-homelab = {
    enable = true;
    user = "mauri";
    sharePath = "/srv/storage/shares";
    lanInterface = "enp2s0";
  };

  # E.1 — share extra para drag-and-drop de PDFs al consume dir de Paperless.
  # El módulo samba-homelab solo declara la share `${user}` por defecto; sumamos
  # esta share via merge directo a services.samba.settings (NixOS attrset merge).
  # forceUser=paperless: archivos drop terminan owned by paperless aunque mauri sea
  # quien los escribe (necesario para que paperless-consumer pueda procesarlos).
  services.samba.settings.paperless-consume = {
    "path" = "/srv/docs/consume";
    "comment" = "Paperless consume drop zone";
    "browseable" = "yes";
    "read only" = "no";
    "guest ok" = "no";
    "valid users" = "mauri";
    "force user" = "paperless";
    "force group" = "paperless";
    "create mask" = "0664";
    "directory mask" = "2775";
  };

  # ── E.1 services ────────────────────────────────────────────────────────────

  services.postgres-shared-homelab = {
    enable = true;
    databases = {
      paperless = {
        user = "paperless";
        secretFile = config.age.secrets.postgresPaperlessPass.path;
      };
      grafana = {
        user = "grafana";
        secretFile = config.age.secrets.postgresGrafanaPass.path;
      };
      nextcloud = {
        user = "nextcloud";
        secretFile = config.age.secrets.postgresNextcloudPass.path;
      };
      immich = {
        user = "immich";
        secretFile = config.age.secrets.postgresImmichPass.path;
      };
      hass = {
        user = "hass";
        secretFile = config.age.secrets.postgresHassPass.path;
      };
    };
  };

  # Postgres user passwords — agenix decryption only (no service-level owner;
  # postgres-set-passwords corre como user `postgres` y lee via LoadCredential).
  age.secrets.postgresPaperlessPass.file = "${inputs.secrets}/secrets/postgres-paperless-pass.age";
  age.secrets.postgresGrafanaPass.file   = "${inputs.secrets}/secrets/postgres-grafana-pass.age";
  age.secrets.postgresNextcloudPass.file = "${inputs.secrets}/secrets/postgres-nextcloud-pass.age";
  age.secrets.postgresImmichPass.file    = "${inputs.secrets}/secrets/postgres-immich-pass.age";
  age.secrets.postgresHassPass.file      = "${inputs.secrets}/secrets/postgres-hass-pass.age";

  # D.3 — Keycloak ZFS encryption key. Declarado en host-level (no en módulo)
  # porque zfs-services-bootstrap.service lo necesita ANTES de que el módulo
  # keycloak-homelab corra. owner=root porque /run/agenix/X se lee por zfs-bootstrap
  # como root.
  age.secrets.keycloakZfsKey = {
    file = "${inputs.secrets}/secrets/keycloak-zfs-key.age";
    owner = "root";
    group = "root";
    mode = "0400";
  };

  services.paperless-homelab.enable = true;

  services.radicale-homelab.enable = true;

  # ── E.3 observabilidad ──────────────────────────────────────────────────────

  services.prometheus-homelab = {
    enable = true;
    retention = "30d";
    scrapeTargets = {
      # paperless expone /metrics? Comentado hasta validar (2.x lo trae detrás
      # de PAPERLESS_ENABLE_METRICS=true). Activar cuando se confirme con curl.
      # paperless = { url = "127.0.0.1:8000"; metricsPath = "/metrics"; };
    };
    blackboxTargets = [
      "https://vault.mauricioantolin.com"
      "https://paperless.mauricioantolin.com"
      "https://whoami.mauricioantolin.com"
      "https://cal.mauricioantolin.com"
    ];
  };

  services.grafana-homelab.enable = true;

  # ── E.2a — Jellyfin ─────────────────────────────────────────────────────────
  services.jellyfin-homelab = {
    enable = true;
    hwAccel = true;
    # Jellyfin 10.11 cambió /Startup/Configuration body format (responde 415 con JSON
    # tradicional). Bootstrap automatizado deshabilitado por brittleness — wizard
    # manual desde UI toma ~30s con el pass de Vaultwarden.
    autoBootstrap = false;
  };

  # ── E.2b — Deluge (Path A no-VPN) ───────────────────────────────────────────
  services.deluge-homelab = {
    enable = true;
    # downloads dirs default OK (/srv/downloads/{incomplete,complete}).
    # Path A behavior config (encryption forced + caps) en el módulo.
  };

  # ── E.2c — *arr stack (Prowlarr + Sonarr + Radarr + Bazarr) ─────────────────
  services.arr-stack-homelab = {
    enable = true;
    # autoBootstrap=true por default → arr-bootstrap.service conecta
    # Prowlarr↔Sonarr/Radarr, Sonarr/Radarr→Deluge, Bazarr↔Sonarr/Radarr.
    # Idempotente (skip si la integración ya existe).
  };

  # ── E.2d — Jellyseerr (UI de requests) ──────────────────────────────────────
  services.jellyseerr-homelab = {
    enable = true;
    # /api/v1/auth/jellyfin responde 404 en jellyseerr 2.7.x — endpoint cambió
    # en versiones nuevas. Bootstrap manual desde UI (login con Jellyfin admin →
    # Sonarr/Radarr settings con API keys que están en /var/lib/{sonarr,radarr}/config.xml).
    autoBootstrap = false;
  };

  # ── D.3 — Keycloak SSO ──────────────────────────────────────────────────────
  # Quarkus distro detrás de CF Tunnel; backend postgres-shared, dataset cifrado.
  # SMTP arranca deshabilitado: hace falta el email del Workspace user (donde
  # se generó el App Password) para activarlo. Una vez confirmado, flip a:
  #   smtp = { enable = true; username = "<workspace-user>@mauricioantolin.com"; };
  # El password ya está en agenix (keycloak-smtp-pass.age).
  services.keycloak-homelab = {
    enable = true;
    smtp = {
      enable = false;
      # Placeholder eval-safe — el módulo lee cfg.smtp.username incluso con
      # smtp.enable=false (para popular la env var SMTP_USER del bootstrap).
      username = "PENDING_WORKSPACE_USER_EMAIL";
    };
  };

  networking = {
    hostName = "home-server";
    hostId = "3834b250";
    useNetworkd = true;
    useDHCP = false;
    nameservers = [ "1.1.1.1" "9.9.9.9" ];
  };

  # Datasets creados en Fase C/E — Nix necesita saber de ellos para montarlos al boot.
  # Nota: `mountpoint=legacy` en ZFS delega el mount a NixOS via fileSystems.
  fileSystems."/var/lib/vaultwarden" = {
    device = "rpool/services/vaultwarden";
    fsType = "zfs";
  };
  fileSystems."/var/lib/uptime-kuma" = {
    device = "rpool/services/uptime-kuma";
    fsType = "zfs";
  };
  fileSystems."/var/lib/homepage" = {
    device = "rpool/services/homepage";
    fsType = "zfs";
  };
  # E.1 — apps stack
  fileSystems."/var/lib/postgresql" = {
    device = "rpool/services/postgres-shared";
    fsType = "zfs";
  };
  fileSystems."/var/lib/paperless" = {
    device = "rpool/services/paperless";
    fsType = "zfs";
  };
  fileSystems."/var/lib/radicale" = {
    device = "rpool/services/radicale";
    fsType = "zfs";
  };
  fileSystems."/srv/docs" = {
    device = "tank/docs";
    fsType = "zfs";
  };
  # E.3 — observabilidad. NixOS prometheus default stateDir=prometheus2 →
  # mountpoint /var/lib/prometheus2 (no /var/lib/prometheus).
  fileSystems."/var/lib/prometheus2" = {
    device = "rpool/services/prometheus";
    fsType = "zfs";
  };
  fileSystems."/var/lib/grafana" = {
    device = "rpool/services/grafana";
    fsType = "zfs";
  };
  # E.2a — Jellyfin + media libraries
  fileSystems."/var/lib/jellyfin" = {
    device = "rpool/services/jellyfin";
    fsType = "zfs";
  };
  fileSystems."/var/cache/jellyfin" = {
    device = "rpool/services/jellyfin-cache";
    fsType = "zfs";
  };
  fileSystems."/srv/storage/media/movies" = {
    device = "tank/storage/media/movies";
    fsType = "zfs";
  };
  fileSystems."/srv/storage/media/tv" = {
    device = "tank/storage/media/tv";
    fsType = "zfs";
  };
  fileSystems."/srv/storage/media/music" = {
    device = "tank/storage/media/music";
    fsType = "zfs";
  };
  # E.2b — Deluge
  fileSystems."/var/lib/deluge" = {
    device = "rpool/services/deluge";
    fsType = "zfs";
  };
  fileSystems."/srv/downloads" = {
    device = "tank/downloads";
    fsType = "zfs";
  };
  # E.2c — *arr stack
  fileSystems."/var/lib/sonarr" = {
    device = "rpool/services/sonarr";
    fsType = "zfs";
  };
  fileSystems."/var/lib/radarr" = {
    device = "rpool/services/radarr";
    fsType = "zfs";
  };
  fileSystems."/var/lib/bazarr" = {
    device = "rpool/services/bazarr";
    fsType = "zfs";
  };
  # E.2d — Jellyseerr: DynamicUser=yes, sin dataset (rpool/var)
  # D.3 — Keycloak (encrypted dataset, key en agenix; load-key vía zfs-services-bootstrap)
  fileSystems."/var/lib/keycloak" = {
    device = "rpool/services/keycloak";
    fsType = "zfs";
  };
  # tank/backups y /srv/backups ya declarados en disko.nix Fase A; postgres-shared
  # escribe a /srv/backups/postgresql (subdir creado via tmpfiles).

  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Name = "en*";
      networkConfig = {
        Address = "192.168.0.17/24";
        Gateway = "192.168.0.1";
        DNS = [ "1.1.1.1" "9.9.9.9" ];
      };
    };
  };

  # home-manager para mauri
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.mauri = import ../../../../users/mauri/home.nix;

  # Pineamos stateVersion (NO cambiar tras primer deploy sin leer release notes).
  system.stateVersion = "25.11";
}
