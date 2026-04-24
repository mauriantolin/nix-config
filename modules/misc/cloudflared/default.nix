{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.cloudflared-homelab;
  secretsRoot = "${inputs.secrets}/secrets";
in
{
  options.services.cloudflared-homelab = {
    enable = lib.mkEnableOption "Cloudflare Tunnel para exponer servicios internos";
    tunnelId = lib.mkOption {
      type = lib.types.str;
      description = ''
        UUID del tunnel creado en CF dashboard (Zero Trust → Networks → Tunnels).
        Si está vacío se toma como placeholder y el módulo no levanta nada.
      '';
      default = "";
    };
    ingress = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Mapa de hostname externo → URL interna (ej: "whoami.example.com" = "http://127.0.0.1:8080").
        El módulo agrega automáticamente el fallback http_status:404.
      '';
      example = { "whoami.example.com" = "http://127.0.0.1:8080"; };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tunnelId != "";
        message = "services.cloudflared-homelab.tunnelId vacío — pasá el UUID del tunnel";
      }
    ];

    services.cloudflared = {
      enable = true;
      tunnels.${cfg.tunnelId} = {
        credentialsFile = config.age.secrets.cloudflaredCredentials.path;
        default = "http_status:404";
        ingress = cfg.ingress;
      };
    };

    age.secrets.cloudflaredCredentials = {
      file = "${secretsRoot}/cloudflared-credentials.age";
      # nixpkgs services.cloudflared usa DynamicUser=true desde 25.11 — el usuario
      # estático `cloudflared` ya no existe. systemd lee el secret como root via
      # `LoadCredential=` y se lo expone al DynamicUser bajo /run/credentials/.
      owner = "root";
      group = "root";
      mode = "0400";
    };

    # QUIC (protocolo que usa cloudflared) necesita buffers UDP más grandes que
    # el default Linux. Sin esto: "failed to sufficiently increase receive buffer size".
    # Ref: https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes
    boot.kernel.sysctl = {
      "net.core.rmem_max" = 7340032;
      "net.core.wmem_max" = 7340032;
    };
  };
}
