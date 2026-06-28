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
    # Núcleo mínimo (tailscale-only): vault + uptime + dashboard + archivos
    ../../../services/vaultwarden
    ../../../services/uptime-kuma
    ../../../services/homepage
    ../../../services/samba
    ../../../../users/mauri
    ./hardware.nix
    ./disko.nix
  ];

  # Auto-create datasets si faltan (DR + dev re-deploy).
  # - postgres-shared: datadir de PostgreSQL (lo gestiona el módulo services.immich).
  # - tank/photos: librería de fotos de Immich en HDD (928 GB libres).
  # Datasets de servicios eliminados quedan en el pool sin montar (data preservada).
  services.zfs-services-bootstrap = {
    enable = true;
    datasets = {
      "rpool/services/postgres-shared" = { recordsize = "8K"; };
      "tank/photos"                    = { recordsize = "1M"; };
    };
    beforeMounts = [
      "var-lib-postgresql.mount"
      "srv-photos.mount"
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

  # ── Immich — fotos. Auto-gestiona su PostgreSQL (extensión VectorChord) + redis.
  # ML off (sin GPU, ahorra RAM). Auth propia de Immich. Media en tank (HDD).
  services.immich = {
    enable = true;
    host = "127.0.0.1";
    port = 2283;
    openFirewall = false;             # acceso solo por tailscale-serve
    mediaLocation = "/srv/photos";
    machine-learning.enable = false;
    settings.server.externalDomain = "https://home-server.tailee5654.ts.net:2283";
  };
  # mediaLocation debe existir y ser de immich antes de arrancar el servicio.
  systemd.tmpfiles.rules = [ "d /srv/photos 0750 immich immich - -" ];

  # nix-ld: shim del dynamic linker para correr binarios precompilados (Python de uv,
  # node prebuilt, etc.) en NixOS. Necesario para el toolchain per-proyecto de los repos.
  programs.nix-ld.enable = true;

  # Acceso HTTPS dentro del tailnet (Tailscale ya autentica → sin oauth2-proxy).
  services.tailscale-serve-homelab = {
    enable = true;
    magicHostname = "home-server.tailee5654.ts.net";
    handlers = {
      homepage     = { Proxy = "http://127.0.0.1:3000"; };
      uptime       = { Proxy = "http://127.0.0.1:3001"; Port = 8443; };
      vaultwarden  = { Proxy = "http://127.0.0.1:8222"; Port = 8222; };
      photos       = { Proxy = "http://127.0.0.1:2283"; Port = 2283; };
    };
  };

  services.samba-homelab = {
    enable = true;
    user = "mauri";
    sharePath = "/srv/storage/shares";
    lanInterface = "enp2s0";
  };

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
  fileSystems."/srv/photos" = {
    device = "tank/photos";
    fsType = "zfs";
  };
  # tank/backups y /srv/backups ya declarados en disko.nix Fase A.

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
