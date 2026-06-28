{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../_common
    ../../../misc/zfs-root
    ../../../misc/tailscale
    ../../../misc/agenix
    ../../../misc/tailscale-serve
    ../../../misc/zfs-services-bootstrap
    # Phase 7a — sanoid local snapshot policy (3 tiers: critical/standard/media)
    ../../../misc/sanoid-homelab
    # Núcleo mínimo (tailscale-only): vault + uptime + dashboard + archivos + postgres
    ../../../services/vaultwarden
    ../../../services/uptime-kuma
    ../../../services/homepage
    ../../../services/samba
    ../../../services/postgres-shared
    ../../../../users/mauri
    ./hardware.nix
    ./disko.nix
  ];

  # Auto-create datasets si faltan (DR + dev re-deploy). Solo postgres-shared:
  # backend de Immich (a desplegar). El resto de datasets de servicios eliminados
  # quedan en el pool sin montar (data preservada, recuperable si se reactivan).
  services.zfs-services-bootstrap = {
    enable = true;
    datasets = {
      "rpool/services/postgres-shared" = { recordsize = "8K"; };
    };
    beforeMounts = [
      "var-lib-postgresql.mount"
    ];
  };

  # Vaultwarden — tailscale-only (sin CF Tunnel, sin SSO). Acceso por tailscale-serve
  # en https://home-server.tailee5654.ts.net:8222. Login local (ADMIN_TOKEN via agenix).
  services.vaultwarden-homelab = {
    enable = true;
    domain = "home-server.tailee5654.ts.net:8222";
    allowSignups = false;
    sso.enable = false;
  };

  services.uptime-kuma-homelab.enable = true;

  services.homepage-homelab.enable = true;

  # Acceso HTTPS dentro del tailnet (Tailscale ya autentica → sin oauth2-proxy).
  services.tailscale-serve-homelab = {
    enable = true;
    magicHostname = "home-server.tailee5654.ts.net";
    handlers = {
      homepage     = { Proxy = "http://127.0.0.1:3000"; };
      uptime       = { Proxy = "http://127.0.0.1:3001"; Port = 8443; };
      vaultwarden  = { Proxy = "http://127.0.0.1:8222"; Port = 8222; };
    };
  };

  services.samba-homelab = {
    enable = true;
    user = "mauri";
    sharePath = "/srv/storage/shares";
    lanInterface = "enp2s0";
  };

  # Postgres compartido — backend de Immich (a desplegar). DBs de servicios
  # eliminados (paperless/grafana/keycloak/nextcloud/hass) removidas.
  services.postgres-shared-homelab = {
    enable = true;
    databases = {
      immich = {
        user = "immich";
        secretFile = config.age.secrets.postgresImmichPass.path;
      };
    };
  };

  age.secrets.postgresImmichPass.file = "${inputs.secrets}/secrets/postgres-immich-pass.age";

  networking = {
    hostName = "home-server";
    hostId = "3834b250";
    useNetworkd = true;
    useDHCP = false;
    nameservers = [ "1.1.1.1" "9.9.9.9" ];
  };

  # Datasets de servicios conservados. mountpoint=legacy en ZFS → mount via NixOS.
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
  fileSystems."/var/lib/postgresql" = {
    device = "rpool/services/postgres-shared";
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
