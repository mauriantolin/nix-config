{ config, lib, pkgs, ... }:
{
  users.mutableUsers = false;

  users.users.mauri = {
    isNormalUser = true;
    uid = 1001;
    description = "Mauricio Antolin";
    extraGroups = [ "wheel" "tailscale" ];
    shell = pkgs.zsh;
    hashedPasswordFile = config.age.secrets.mauri-password.path;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM0/mKSFJ9hlyypK0uf3n55WDh/TCVWP8Rbbv9HAQl/q mauriantolin5@gmail.com"
    ];
  };

  users.groups.mauri.gid = 1001;

  programs.zsh.enable = true;
}
