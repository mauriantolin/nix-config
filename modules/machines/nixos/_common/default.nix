{ config, lib, pkgs, inputs, ... }:
{
  # === Boot / kernel ===
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # kernelPackages lo define el módulo zfs-root (pin al último compatible con ZFS).
  # Los hosts sin ZFS pueden setearlo explícitamente en su host module.
  # ARC cap 2 GB (justificación: RAM total 8 GB, cap para servicios).
  boot.kernelParams = [ "zfs.zfs_arc_max=2147483648" ];

  # === Nix settings ===
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "@wheel" ];
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # === Locale / tiempo ===
  time.timeZone = "America/Argentina/Buenos_Aires";
  i18n.defaultLocale = "es_AR.UTF-8";
  i18n.supportedLocales = [ "es_AR.UTF-8/UTF-8" "en_US.UTF-8/UTF-8" ];
  console.keyMap = "la-latin1";

  # === SSH (solo pubkey) ===
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      X11Forwarding = false;
    };
  };

  # === Firewall ===
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    trustedInterfaces = [ "tailscale0" "lo" ];
    allowPing = true;
  };

  # === fail2ban local (SSH LAN; fail2ban-cloudflare es Fase B) ===
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
  };

  # === zram swap ===
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  # === Paquetes mínimos globales ===
  environment.systemPackages = with pkgs; [
    vim
    curl
    wget
    git
    htop
    tmux
    zfs
  ];

  # === sudo sin password para wheel (clave privada como único factor) ===
  security.sudo.wheelNeedsPassword = false;

  # === Nixpkgs config ===
  nixpkgs.config.allowUnfree = true;
}
