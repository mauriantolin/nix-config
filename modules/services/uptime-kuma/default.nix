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
  };

  config = lib.mkIf cfg.enable {
    # Plan B (post brainstorm): Kuma corre en root, expuesto por Tailscale Serve en puerto
    # dedicado :8443. El subpath `/uptime/` se descartó porque Kuma redirige a /dashboard
    # absoluto bajo reverse proxy, rompiendo el routing.
    services.uptime-kuma = {
      enable = true;
      settings = {
        PORT = toString cfg.port;
        # 0.0.0.0 permite que el bridge de podman (10.88.0.1) alcance Kuma desde
        # el container de Homepage vía `host.containers.internal:3001`.
        # Exposición: :3001 queda en tailscale0 también, pero tailnet es trusted y
        # Tailscale Serve ya expone lo mismo en :8443 — redundante, no nuevo vector.
        # LAN (enp2s0): firewall no abre :3001, sigue bloqueado.
        HOST = "0.0.0.0";
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
        # StateDirectory vacío: dataset ZFS ya montado; no dejar que systemd lo gestione ni lo renombre.
        StateDirectory = lib.mkForce "";
        User = "uptime-kuma";
        Group = "uptime-kuma";
        # ProtectSystem=strict bloquea escrituras a /var/lib sin StateDirectory.
        # Habilitamos acceso explícito al dataset ZFS.
        ReadWritePaths = [ "/var/lib/uptime-kuma" ];
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
