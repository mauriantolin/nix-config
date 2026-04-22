# Overlay aplicado sobre home-server para producir home-server-vm.
# Reemplaza disko real + net estática LAN por layout compatible con una VM Hetzner.
{ config, lib, pkgs, ... }:
{
  # Disko en VM: single disk /dev/sda, sin HDD secundario, sin ZFS (ext4 simple para V1).
  # Objetivo V1 no es probar ZFS en VM, sino que el resto del flake evalúe + nixos-anywhere funcione.
  disko.devices = lib.mkForce {
    disk.main = {
      type = "disk";
      device = "/dev/sda";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; };
          };
          root = {
            size = "100%";
            content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };
          };
        };
      };
    };
  };

  # En VM usamos DHCP del hypervisor.
  systemd.network.networks = lib.mkForce { };
  networking.useDHCP = lib.mkForce true;

  # hostId distinto para evitar colisión con home-server real si corren simultáneos.
  networking.hostId = lib.mkForce "deadbeef";
  networking.hostName = lib.mkForce "home-server-vm";

  # ZFS off en VM V1 (probamos ZFS real en el install físico).
  boot.supportedFilesystems = lib.mkForce [ "ext4" "vfat" ];
  services.zfs.autoScrub.enable = lib.mkForce false;
  boot.zfs.forceImportRoot = lib.mkForce false;

  # ARC cap no aplica sin ZFS.
  boot.kernelParams = lib.mkForce [ ];
}
