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

    # El módulo nixpkgs usa DynamicUser=true + PrivateUsers=true, lo que hace que systemd
    # intente renombrar /var/lib/uptime-kuma → /var/lib/private/uptime-kuma.
    # Como /var/lib/uptime-kuma es un dataset ZFS montado, eso falla con "Device or resource busy".
    # Solución: desactivamos DynamicUser/PrivateUsers y creamos un usuario estático.
    users.users.uptime-kuma = {
      isSystemUser = true;
      group = "uptime-kuma";
      home = "/var/lib/uptime-kuma";
    };
    users.groups.uptime-kuma = {};

    systemd.services.uptime-kuma = {
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        PrivateUsers = lib.mkForce false;
        StateDirectory = lib.mkForce "";   # dataset ZFS ya montado; no dejar que systemd lo gestione
        User = "uptime-kuma";
        Group = "uptime-kuma";
      };
    };

    # Aseguramos ownership del dataset ZFS montado (Phase 2) para el user estático uptime-kuma.
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
