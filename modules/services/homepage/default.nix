{ config, lib, pkgs, ... }:
let
  cfg = config.services.homepage-homelab;

  # Archivos de configuración declarativos en el store de Nix.
  servicesCfg  = ./config/services.yaml;
  bookmarksCfg = ./config/bookmarks.yaml;
  widgetsCfg   = ./config/widgets.yaml;
  settingsCfg  = ./config/settings.yaml;
  dockerCfg    = ./config/docker.yaml;
in
{
  options.services.homepage-homelab = {
    enable = lib.mkEnableOption "Homepage dashboard (OCI container, tailnet-only)";
    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/gethomepage/homepage:v0.10.9";
      description = "Imagen pineada; bumpear manualmente con smoke test.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
    };
    allowedHosts = lib.mkOption {
      type = lib.types.str;
      default = "home-server.tailee5654.ts.net,localhost,127.0.0.1";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
      defaultNetwork.settings.dns_enabled = true;
    };
    virtualisation.oci-containers.backend = "podman";

    virtualisation.oci-containers.containers.homepage = {
      image = cfg.image;
      # Phase 8 — `--network=host` permite que widgets alcancen servicios on-host
      # bind a 127.0.0.1 (paperless/grafana/prometheus/alertmanager) sin hacer
      # 0.0.0.0-bind a cada uno. HOSTNAME=127.0.0.1 mantiene homepage también en
      # loopback. `ports` se ignora en host mode (mutex con port-mapping).
      ports = [ ];
      environment = {
        HOMEPAGE_ALLOWED_HOSTS = cfg.allowedHosts;
        # PUID/PGID=0 → node corre como root. Motivos: (1) acceso al socket
        # rootful de podman sin depender de grupos suplementarios (su-exec del
        # entrypoint los resetea al dropear a un uid no-root), (2) el entrypoint
        # saltea el `chown -R /app` (que sobre este CPU tardaba minutos en cada
        # arranque). Aceptable: container tailnet-only y el socket ya es
        # root-equivalente para cualquiera que lo monte.
        PUID = "0";
        PGID = "0";
        HOSTNAME = "127.0.0.1";
      };
      # Auto-discovery de contenedores: Homepage lee estos labels del propio
      # container (vía el socket de podman) y lo muestra solo en el dashboard.
      # Patrón replicable: cualquier oci-container futuro que ponga labels
      # `homepage.*` aparece automáticamente sin tocar services.yaml.
      labels = {
        "homepage.group"       = "Containers";
        "homepage.name"        = "Homepage";
        "homepage.icon"        = "homepage.png";
        "homepage.href"        = "https://home-server.tailee5654.ts.net";
        "homepage.description" = "Este dashboard";
      };
      volumes = [
        # /var/lib/homepage/config es un directorio escribible; los archivos se
        # copian allí en cada activación por el servicio homepage-config-sync.
        "/var/lib/homepage/config:/app/config"
        "/var/lib/homepage/icons:/app/public/icons"
        # Socket de podman (docker-API compatible) → widget de contenedores.
        # NO montar :ro — connect() a un unix socket requiere permiso de
        # escritura y un bind-mount read-only lo bloquea con EACCES.
        "/run/podman/podman.sock:/var/run/docker.sock"
        # Dataset de tank (HDD) para el widget de disco (statvfs de /mnt/tank).
        "/srv/storage:/mnt/tank:ro"
      ];
      extraOptions = [ "--pull=missing" "--network=host" ];
    };

    # Copia los archivos de config (del store de Nix, inmutables) a un
    # directorio escribible antes de que arranque el contenedor.
    systemd.services.homepage-config-sync = {
      description = "Sync homepage declarative config to writable directory";
      wantedBy = [ "podman-homepage.service" ];
      before    = [ "podman-homepage.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 755 -o 1000 -g 1000 /var/lib/homepage/config
        install -m 644 -o 1000 -g 1000 ${servicesCfg}  /var/lib/homepage/config/services.yaml
        install -m 644 -o 1000 -g 1000 ${bookmarksCfg} /var/lib/homepage/config/bookmarks.yaml
        install -m 644 -o 1000 -g 1000 ${widgetsCfg}   /var/lib/homepage/config/widgets.yaml
        install -m 644 -o 1000 -g 1000 ${settingsCfg}  /var/lib/homepage/config/settings.yaml
        install -m 644 -o 1000 -g 1000 ${dockerCfg}    /var/lib/homepage/config/docker.yaml
      '';
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/homepage        0755 1000 1000 -"
      "d /var/lib/homepage/config 0755 1000 1000 -"
      "d /var/lib/homepage/icons  0755 1000 1000 -"
    ];

    # El bridge de podman (podman0, 10.88.0.0/16) necesita ser "trusted" en el
    # firewall para que containers puedan alcanzar servicios del host. Sin esto,
    # paquetes entrando por podman0 con destino a :3001 (Kuma) son dropeados.
    # Scope: sólo containers en ese bridge, no tráfico externo.
    networking.firewall.trustedInterfaces = [ "podman0" ];

    # Phase 8 — `--network=host` + Next.js bind a *:3000 (HOSTNAME env no-op en
    # esta versión) → puerto :3000 quedaría reachable vía tailscale0 (trusted iface)
    # bypass-eando oauth2-proxy. Drop explícito para cualquier iface != lo, lo
    # que mantiene oauth2-proxy(:4186)→127.0.0.1:3000 funcional pero corta acceso
    # directo desde tailnet/LAN. Insertado al top de nixos-fw para evitar que el
    # ACCEPT de tailscale0 se aplique primero.
    networking.firewall.extraCommands = ''
      iptables -I nixos-fw '!' -i lo -p tcp --dport ${toString cfg.port} -j DROP
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D nixos-fw '!' -i lo -p tcp --dport ${toString cfg.port} -j DROP 2>/dev/null || true
    '';
  };
}
