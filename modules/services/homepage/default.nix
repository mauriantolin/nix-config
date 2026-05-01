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
      ports = [ "127.0.0.1:${toString cfg.port}:3000" ];
      environment = {
        HOMEPAGE_ALLOWED_HOSTS = cfg.allowedHosts;
        PUID = "1000";
        PGID = "1000";
      };
      volumes = [
        # /var/lib/homepage/config es un directorio escribible; los archivos se
        # copian allí en cada activación por el servicio homepage-config-sync.
        "/var/lib/homepage/config:/app/config"
        "/var/lib/homepage/icons:/app/public/icons"
      ];
      extraOptions = [ "--pull=missing" ];
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
  };
}
