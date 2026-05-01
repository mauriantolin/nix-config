{ config, lib, pkgs, ... }:
let
  cfg = config.services.homepage-homelab;
  configDir = pkgs.runCommand "homepage-config" { } ''
    mkdir -p $out
    cp ${./config/services.yaml}  $out/services.yaml
    cp ${./config/bookmarks.yaml} $out/bookmarks.yaml
    cp ${./config/widgets.yaml}   $out/widgets.yaml
    cp ${./config/settings.yaml}  $out/settings.yaml
    cp ${./config/docker.yaml}    $out/docker.yaml
  '';
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
        "${configDir}:/app/config:ro"
        "/var/lib/homepage/icons:/app/public/icons"
      ];
      extraOptions = [ "--pull=missing" ];
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/homepage       0755 1000 1000 -"
      "d /var/lib/homepage/icons 0755 1000 1000 -"
    ];
  };
}
