{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.vaultwarden-homelab;
  secretsRoot = "${inputs.secrets}/secrets";
in
{
  options.services.vaultwarden-homelab = {
    enable = lib.mkEnableOption "Vaultwarden homelab wrapper (nativo nixpkgs + agenix + CF tunnel ingress)";
    domain = lib.mkOption {
      type = lib.types.str;
      default = "vault.mauricioantolin.com";
      description = "Hostname público que enruta cloudflared a Vaultwarden.";
    };
    allowSignups = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        SIGNUPS_ALLOWED. Flip a `true` solo durante el bootstrap del primer usuario.
        Dejarlo en `false` en régimen normal; agregar usuarios por admin panel.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.vaultwarden = {
      enable = true;
      dbBackend = "sqlite";
      environmentFile = config.age.secrets.vaultwardenAdminToken.path;
      config = {
        ROCKET_ADDRESS       = "127.0.0.1";
        ROCKET_PORT          = 8222;
        DOMAIN               = "https://${cfg.domain}";
        SIGNUPS_ALLOWED      = cfg.allowSignups;
        SIGNUPS_VERIFY       = false;
        INVITATIONS_ALLOWED  = true;
        SHOW_PASSWORD_HINT   = false;
        LOG_LEVEL            = "warn";
        EXTENDED_LOGGING     = true;
        IP_HEADER            = "CF-Connecting-IP";
      };
    };

    age.secrets.vaultwardenAdminToken = {
      file  = "${secretsRoot}/vaultwarden-admin-token.age";
      # vaultwarden corre como usuario `vaultwarden` (creado por nixpkgs module).
      owner = "vaultwarden";
      group = "vaultwarden";
      mode  = "0400";
    };

    # /var/lib/vaultwarden ya tiene su dataset ZFS montado (Phase 2). Aseguramos
    # ownership correcto al boot por si NixOS lo dejó como root.
    systemd.services.vaultwarden-data-chown = {
      after = [ "local-fs.target" ];
      before = [ "vaultwarden.service" ];
      wantedBy = [ "vaultwarden.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/chown -R vaultwarden:vaultwarden /var/lib/vaultwarden";
      };
    };
  };
}
