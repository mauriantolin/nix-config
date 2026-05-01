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
    };
    beforeMounts = [
      "var-lib-postgresql.mount"
      "var-lib-paperless.mount"
      "var-lib-radicale.mount"
      "srv-docs.mount"
      # E.3
      "var-lib-prometheus2.mount"
      "var-lib-grafana.mount"
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
