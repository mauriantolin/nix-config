# Este archivo se REEMPLAZA por el output de `nixos-generate-config --show-hardware-config`
# durante el install físico real. En V1 se genera en la VM Hetzner.
# Placeholder intencional para que `nix flake check` evalúe sin romper.
{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # Módulos típicos para Haswell + SATA — el real se genera con nixos-generate-config.
  boot.initrd.availableKernelModules = [ "xhci_pci" "ehci_pci" "ahci" "usb_storage" "sd_mod" ];
  boot.kernelModules = [ "kvm-intel" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
