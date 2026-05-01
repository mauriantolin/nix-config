{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.radicale-homelab;
  secretsRoot = "${inputs.secrets}/secrets";
in
{
  options.services.radicale-homelab = {
    enable = lib.mkEnableOption "Radicale CalDAV/CardDAV server (htpasswd bcrypt)";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "cal.mauricioantolin.com";
      description = ''
        Hostname público que enruta cloudflared a Radicale.
        Q1 RESUELTO: CF Access tiene policy de BYPASS para este hostname porque
        clientes CalDAV (iPhone, DAVx5, Thunderbird) no soportan OAuth flow.
        Auth queda enteramente en radicale htpasswd bcrypt.
      '';
    };

    storageDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/radicale/collections";
      description = "Directorio raíz de las collections (calendarios + contactos).";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets.radicaleHtpasswd = {
      file  = "${secretsRoot}/radicale-htpasswd.age";
      # Usado vía LoadCredential que copia a tmpfs como root → service. owner=root OK.
      owner = "root";
      group = "root";
      mode  = "0400";
    };

    # NixOS module corre como user `radicale` con DynamicUser. LoadCredential expone
    # el htpasswd file en %d/radicale.htpasswd dentro del unit, leído por radicale.
    # Patrón heredado del módulo notthebee, ajustado a bcrypt en lugar de plain.
    systemd.services.radicale.serviceConfig.LoadCredential =
      "radicale.htpasswd:${config.age.secrets.radicaleHtpasswd.path}";

    services.radicale = {
      enable = true;
      # extraArgs sobreescribe la config de auth con path dinámico de LoadCredential.
      # %d expande a $CREDENTIALS_DIRECTORY (tmpfs solo legible por el unit).
      extraArgs = [
        "--auth-htpasswd-filename=%d/radicale.htpasswd"
        "--auth-htpasswd-encryption=bcrypt"
      ];
      settings = {
        server = {
          hosts = [ "127.0.0.1:5232" ];
          max_connections = 20;
          max_content_length = 10485760;   # 10 MB (calendarios pesados con muchos eventos)
          timeout = 30;
          ssl = false;   # CF Tunnel termina TLS upstream
        };

        encoding = {
          request = "utf-8";
          stock = "utf-8";
        };

        auth = {
          type = "htpasswd";
          # htpasswd_filename + htpasswd_encryption se setean via extraArgs (path dinámico)
          # cache_logins evita pagar bcrypt cost en cada request del cliente CalDAV.
          cache_logins = true;
          cache_successful_logins_expiry = 300;   # 5 min
        };

        rights = {
          type = "owner_only";   # cada user solo accede a /<user>/* collections
        };

        storage = {
          type = "multifilesystem";
          filesystem_folder = cfg.storageDir;
        };

        web = {
          type = "internal";   # admin UI básica para crear/listar collections
        };

        logging = {
          level = "info";
        };
      };
    };

    # Asegurar que el unit puede escribir al storage dir (override DynamicUser confinement).
    systemd.services.radicale.serviceConfig.ReadWritePaths = [ cfg.storageDir ];
  };
}
