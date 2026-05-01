{ config, lib, pkgs, ... }:
{
  # Servicio de humo para probar ingress end-to-end: nginx en 127.0.0.1:8080
  # respondiendo texto plano con variables útiles para diagnosticar el pipe CF Tunnel.
  # Solo escucha en loopback: el firewall no abre 8080, cloudflared (mismo host) sí alcanza.
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;

    defaultListen = [
      { addr = "127.0.0.1"; port = 8080; ssl = false; }
    ];

    virtualHosts."whoami" = {
      default = true;
      locations."/" = {
        extraConfig = ''
          default_type "text/plain; charset=utf-8";
          return 200 "home-server online\nHostname: $hostname\nServer time: $time_iso8601\nClient IP (direct): $remote_addr\nX-Forwarded-For: $http_x_forwarded_for\nCF-Connecting-IP: $http_cf_connecting_ip\nCF-Ray: $http_cf_ray\nURI: $request_uri\n";
        '';
      };
    };
  };
}
