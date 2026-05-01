{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../_common
    ../../../misc/zfs-root
    ../../../misc/tailscale
    ../../../misc/agenix
    ../../../../users/mauri
    ./hardware.nix
    ./disko.nix
  ];

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
