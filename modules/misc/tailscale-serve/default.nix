{ config, lib, pkgs, ... }:
let
  cfg = config.services.tailscale-serve-homelab;

  # Itera handlers y emite una línea `tailscale serve` por cada uno.
  # Cada handler: Port (default 443) + Path (default /) + Proxy (URL backend).
  # tailscale 1.90 sintaxis:
  #   - Path = "/" → omitir flag → `tailscale serve --bg --https=PORT http://...`
  #   - Path != "/" → `tailscale serve --bg --https=PORT --set-path=PATH http://...`
  # Múltiples handlers en el mismo Port son OK siempre que sus Path no se solapen.
  handlerLines = lib.concatMapStringsSep "\n"
    (name:
      let
        h = cfg.handlers.${name};
        pathFlag = if h.Path == "/" then "" else "--set-path=${h.Path}";
      in
      ''
        # ${name}
        "$TS" serve --bg --https=${toString h.Port} ${pathFlag} ${h.Proxy}
      ''
    )
    (lib.attrNames cfg.handlers);
in
{
  options.services.tailscale-serve-homelab = {
    enable = lib.mkEnableOption "Imperative tailscale serve config, tailnet-only HTTPS";

    magicHostname = lib.mkOption {
      type    = lib.types.str;
      default = "home-server.tailee5654.ts.net";
      description = "Magic DNS hostname of this node in the tailnet.";
    };

    handlers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          Proxy = lib.mkOption {
            type = lib.types.str;
            example = "http://127.0.0.1:3000";
            description = "URL del backend al que tailscale serve hace reverse proxy.";
          };
          Port = lib.mkOption {
            type = lib.types.port;
            default = 443;
            description = "HTTPS port en el que escucha tailscale serve.";
          };
          Path = lib.mkOption {
            type = lib.types.str;
            default = "/";
            description = ''
              Path mountpoint dentro del puerto. Permite múltiples handlers
              sobre el mismo port (ej. / + /grafana/ ambos en :443).
              Para servicios que rompen bajo subpath (Kuma): usar Path=/ + Port distinto.
            '';
          };
        };
      });
      default = { };
      description = ''
        Mapa de <name> → { Port; Path; Proxy }. El attr name es decorativo
        (se usa solo para comentar la línea generada). Útil para describir el servicio.
      '';
      example = lib.literalExpression ''
        {
          homepage  = { Proxy = "http://127.0.0.1:3000"; };
          grafana   = { Proxy = "http://127.0.0.1:3030"; Path = "/grafana/"; };
          uptime    = { Proxy = "http://127.0.0.1:3001"; Port = 8443; };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Allow tailscaled to request Let's Encrypt certs via ACME on behalf of root.
    services.tailscale.permitCertUid = "root";

    # ------------------------------------------------------------------ #
    # Apply the serve config imperatively (tailscale 1.90 has no --set-raw)
    # ------------------------------------------------------------------ #
    systemd.services.tailscale-serve-config = {
      description = "Apply imperative tailscale serve config from cfg.handlers";
      after    = [ "tailscaled.service" "network-online.target" ];
      wants    = [ "tailscaled.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type             = "oneshot";
        RemainAfterExit  = true;
        Restart          = "on-failure";
        RestartSec       = "10s";
        ExecStart = pkgs.writeShellScript "tailscale-serve-apply.sh" ''
          set -euo pipefail
          TS="${pkgs.tailscale}/bin/tailscale"

          # Reset any previous config to ensure idempotency.
          "$TS" serve reset || true

          ${handlerLines}
        '';
      };
    };

    # ------------------------------------------------------------------ #
    # Force first-time TLS cert issuance
    # ------------------------------------------------------------------ #
    systemd.services.tailscale-cert-bootstrap = {
      description = "Force first-time TLS cert issuance for ${cfg.magicHostname}";
      after    = [ "tailscale-serve-config.service" ];
      wants    = [ "tailscale-serve-config.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        ExecStart       = "${pkgs.tailscale}/bin/tailscale cert ${cfg.magicHostname}";
      };
    };
  };
}
