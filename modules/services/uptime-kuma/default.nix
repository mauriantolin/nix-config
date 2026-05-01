{ config, lib, pkgs, ... }:
let
  cfg = config.services.uptime-kuma-homelab;
in
{
  options.services.uptime-kuma-homelab = {
    enable = lib.mkEnableOption "Uptime Kuma homelab wrapper (nativo, detrás de Tailscale Serve)";
    port = lib.mkOption {
      type = lib.types.port;
      default = 3001;
    };
    basePath = lib.mkOption {
      type = lib.types.str;
      default = "/uptime";
      description = "Subpath donde Tailscale Serve lo enruta. Debe matchear el routing en tailscale-serve.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.uptime-kuma = {
      enable = true;
      settings = {
        PORT = toString cfg.port;
        HOST = "127.0.0.1";
        UPTIME_KUMA_BASE_URL = cfg.basePath;
      };
    };

    # Aseguramos ownership del dataset ZFS montado (Phase 2) para el user uptime-kuma
    # que crea el módulo nixpkgs.
    systemd.services.uptime-kuma-data-chown = {
      after = [ "local-fs.target" ];
      before = [ "uptime-kuma.service" ];
      wantedBy = [ "uptime-kuma.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/chown -R uptime-kuma:uptime-kuma /var/lib/uptime-kuma";
      };
    };
  };
}
