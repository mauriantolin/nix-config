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
    ../../../services/whoami
    ../../../services/vaultwarden
    ../../../services/uptime-kuma
    ../../../services/homepage
    ../../../services/samba
    ../../../../users/mauri
    ./hardware.nix
    ./disko.nix
  ];

  # Fase B — Cloudflare Tunnel activo. Credenciales en agenix cloudflared-credentials.age.
  services.cloudflared-homelab = {
    enable = true;
    tunnelId = "f97802ac-24f1-4810-8042-3d207292eb78";
    ingress = {
      "whoami.mauricioantolin.com" = "http://127.0.0.1:8080";
      "vault.mauricioantolin.com" = "http://127.0.0.1:8222";
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
  };

  services.uptime-kuma-homelab.enable = true;

  services.homepage-homelab.enable = true;

  services.tailscale-serve-homelab = {
    enable = true;
    magicHostname = "home-server.tailee5654.ts.net";
    handlers = {
      "/" = { Proxy = "http://127.0.0.1:3000"; };
      "/uptime/" = { Proxy = "http://127.0.0.1:3001"; };
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

  # Datasets creados en Fase C — Nix necesita saber de ellos para montarlos al boot.
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
