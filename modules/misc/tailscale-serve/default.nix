{ config, lib, pkgs, ... }:
let
  cfg = config.services.tailscale-serve-homelab;
in
{
  options.services.tailscale-serve-homelab = {
    enable = lib.mkEnableOption "Imperative tailscale serve config, tailnet-only HTTPS";

    magicHostname = lib.mkOption {
      type    = lib.types.str;
      default = "home-server.tailee5654.ts.net";
      description = "Magic DNS hostname of this node in the tailnet.";
    };

    # Kept for documentation purposes — with imperative tailscale serve the two
    # backends (Homepage :3000 and Kuma :3001) are hardcoded in the ExecStart
    # script because tailscale 1.90 does not support declarative --set-raw.
    handlers = lib.mkOption {
      type    = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = {
        "/"        = { Proxy = "http://127.0.0.1:3000"; };
        "/uptime/" = { Proxy = "http://127.0.0.1:3001"; };
      };
      description = "Documentation-only: backend mapping (not consumed by the imperative script).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Allow tailscaled to request Let's Encrypt certs via ACME on behalf of root.
    services.tailscale.permitCertUid = "root";

    # ------------------------------------------------------------------ #
    # Apply the serve config imperatively (tailscale 1.90 has no --set-raw)
    # ------------------------------------------------------------------ #
    systemd.services.tailscale-serve-config = {
      description = "Apply imperative tailscale serve config (/ → :3000, /uptime → :3001)";
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

          # / → Homepage on :3000
          "$TS" serve --bg --https=443 http://127.0.0.1:3000

          # /uptime → Uptime Kuma on :3001
          "$TS" serve --bg --https=443 --set-path /uptime http://127.0.0.1:3001
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
