{ config, lib, pkgs, inputs, ... }:
{
  # === Boot / kernel ===
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # kernelPackages lo define el módulo zfs-root (pin al último compatible con ZFS).
  # Los hosts sin ZFS pueden setearlo explícitamente en su host module.
  # ARC cap 2 GB (justificación: RAM total 8 GB, cap para servicios).
  boot.kernelParams = [ "zfs.zfs_arc_max=2147483648" ];

  # === Auto-recovery sysctls (lección post-incident E.1 2026-04-25) ===
  # Auto-reboot 10s después de kernel panic. Cubre 90% de hangs no-hardware.
  # Sin esto, una OOM masiva, deadlock, o oops puede dejar la máquina muerta
  # hasta intervención física.
  boot.kernel.sysctl = {
    "kernel.panic" = 10;
    "kernel.panic_on_oops" = 1;           # tratar oops kernel como panic
    "kernel.hung_task_timeout_secs" = 30; # detectar tareas colgadas en 30s
  };

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

  # SSH outbound: que root use el host key para github.com, así `nixos-rebuild switch`
  # puede fetch-ear el input privado `secrets` (git+ssh://git@github.com/…/nix-private)
  # sin necesidad de GIT_SSH_COMMAND manual en cada deploy.
  # El pubkey del host está registrado como deploy key read-only en nix-private.
  programs.ssh.extraConfig = ''
    Host github.com
      IdentityFile /etc/ssh/ssh_host_ed25519_key
      IdentitiesOnly yes
      StrictHostKeyChecking accept-new
  '';

  # === Firewall ===
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    trustedInterfaces = [ "tailscale0" "lo" ];
    allowPing = true;
  };

  # === fail2ban local (SSH LAN; fail2ban-jails-homelab es Fase B/D.1) ===
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
