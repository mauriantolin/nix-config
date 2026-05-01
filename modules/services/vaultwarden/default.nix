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

    sso = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Habilitar SSO via Keycloak. Activa el overlay con el fork
          Timshel/vaultwarden (upstream no tiene SSO) + web vault con botón
          "Use Single-Sign On". El primer build compila Rust ~5-10 min.

          User mauri sigue pudiendo loguear con master password local (botón
          "Use Single-Sign On" es opcional, no override).

          SSO_SIGNUPS_MATCH_EMAIL=true → si KC user tiene email que ya existe
          en VW, se asocia. Si no existe, allowSignups=true permite auto-create.
        '';
      };
      authority = lib.mkOption {
        type = lib.types.str;
        default = "https://auth.mauricioantolin.com/realms/homelab";
        description = "Issuer URL del realm Keycloak.";
      };
      clientId = lib.mkOption {
        type = lib.types.str;
        default = "vaultwarden";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Overlay con el fork Timshel/vaultwarden cuando SSO está habilitado.
    # Se aplica solo en este host (no en el resto del flake) porque toca un
    # paquete del nixpkgs por completo.
    nixpkgs.overlays = lib.mkIf cfg.sso.enable [ (import ./sso-overlay.nix) ];

    services.vaultwarden = {
      enable = true;
      dbBackend = "sqlite";
      # Multiple env files: el primer agenix tiene ADMIN_TOKEN; cuando sso.enable
      # se agrega el segundo con SSO_CLIENT_SECRET. Ambos los renderiza systemd
      # antes de arrancar el unit.
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
      } // lib.optionalAttrs cfg.sso.enable {
        SSO_ENABLED                  = true;
        SSO_ONLY                     = false;             # local login sigue activo
        SSO_AUTHORITY                = cfg.sso.authority;
        SSO_CLIENT_ID                = cfg.sso.clientId;
        # SSO_CLIENT_SECRET viene via env file (no inline porque es secreto)
        SSO_PKCE                     = true;
        SSO_SCOPES                   = "email profile";   # openid es implícito
        SSO_SIGNUPS_MATCH_EMAIL      = true;              # auto-link KC email ↔ VW user
        SSO_AUTH_ONLY_NOT_SESSION    = false;             # KC controla session lifecycle
        SIGNUPS_ALLOWED              = true;              # SSO crea VW users at first login
      };
    };

    age.secrets.vaultwardenAdminToken = {
      file  = "${secretsRoot}/vaultwarden-admin-token.age";
      # vaultwarden corre como usuario `vaultwarden` (creado por nixpkgs module).
      owner = "vaultwarden";
      group = "vaultwarden";
      mode  = "0400";
    };

    # SSO_CLIENT_SECRET inyectado via systemd Environment a partir del agenix.
    # El módulo NixOS no acepta múltiples environmentFile arrays directamente,
    # así que lo metemos como override del unit cuando SSO está on.
    age.secrets.vaultwardenSsoSecret = lib.mkIf cfg.sso.enable {
      file  = "${secretsRoot}/oidc-client-vaultwarden.age";
      owner = "vaultwarden";
      group = "vaultwarden";
      mode  = "0400";
    };

    # Inyectar SSO_CLIENT_SECRET via env file separado (los inputs sumen).
    systemd.services.vaultwarden.serviceConfig = lib.mkIf cfg.sso.enable {
      EnvironmentFile = [
        # El primer EnvironmentFile lo declara services.vaultwarden con el
        # admin token; agregamos un segundo con el SSO secret. mkIf garantiza
        # que solo se aplica con SSO on; lib.mkAfter mantiene el orden.
        (lib.mkAfter "/run/vaultwarden-sso/sso.env")
      ];
    };

    systemd.services.vaultwarden-sso-env-prepare = lib.mkIf cfg.sso.enable {
      description = "Render SSO_CLIENT_SECRET env file from agenix";
      after = [ "agenix.service" ];
      before = [ "vaultwarden.service" ];
      wantedBy = [ "vaultwarden.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        umask 077
        install -d -m 0750 -o vaultwarden -g vaultwarden /run/vaultwarden-sso
        secret=$(cat ${config.age.secrets.vaultwardenSsoSecret.path})
        cat > /run/vaultwarden-sso/sso.env <<EOF
        SSO_CLIENT_SECRET=$secret
        EOF
        chown vaultwarden:vaultwarden /run/vaultwarden-sso/sso.env
        chmod 0400 /run/vaultwarden-sso/sso.env
      '';
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
