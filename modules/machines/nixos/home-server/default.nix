{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../_common
    ../../../misc/zfs-root
    ../../../misc/tailscale
    ../../../misc/agenix
    ../../../misc/cloudflared
    ../../../services/whoami
    ../../../../users/mauri
    ./hardware.nix
    ./disko.nix
  ];

  # Fase B — Cloudflare Tunnel. Gated off hasta tener tunnelId + .age con credenciales.
  # Una vez encryptadas con agenix, flip enable = true y deploy.
  services.cloudflared-homelab = {
    enable = false;
    tunnelId = "";
    ingress = {
      "whoami.mauricioantolin.com" = "http://127.0.0.1:8080";
    };
  };

  networking = {
    hostName = "home-server";
    hostId = "3834b250";
    useNetworkd = true;
    useDHCP = false;
    nameservers = [ "1.1.1.1" "9.9.9.9" ];
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
