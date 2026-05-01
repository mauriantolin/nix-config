# oauth2-proxy multi-instance — D.4b
#
# Para cada servicio listado en `instances`, levanta un oauth2-proxy independiente
# (systemd service oauth2-proxy-<name>) que valida sesión via Keycloak y proxea al
# backend local. Una sola instancia oauth2-proxy = un client OIDC.
#
# Diseño
# ──────
# - Provider: keycloak-oidc (issuer = realm homelab).
# - Listen 127.0.0.1:<listenPort> (loopback). Exposure pública via cloudflared
#   o vía tailscale-serve, ambos terminan TLS y forwardan X-Forwarded-*.
# - reverse-proxy=true → confía en X-Forwarded-{Proto,Host,Uri} para derivar el
#   redirect_uri por request. Esto permite que la *misma* instancia maneje
#   accesos via TS Serve (home-server.tailee5654.ts.net:NNNN) y CF Tunnel
#   (service.mauricioantolin.com) sin hardcodear redirect-url.
#   KC realm tiene ambas variantes de redirect URI registradas por cliente.
# - cookie-secret compartido por todas las instancias (mismo agenix file). El
#   cookie es scope-host por default, no se filtra entre servicios; el secret
#   común solo simplifica la rotación.
# - Cada client-secret es un agenix .age distinto (oidc-client-oauth2proxy-<svc>).
#
# No-goals
# ────────
# - No upstream-passthrough headers a la app (X-Forwarded-User/Email): primer
#   deploy mantiene el auth interno de cada servicio como segundo paso. Iter 2
#   wireará "AuthenticationMethod=External" en *arr para que confíen el header
#   y skippeen su propia login screen.
# - No allowlist por grupo: realm "homelab" ya filtra usuarios. emailDomain="*"
#   acepta cualquier user autenticado.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.oauth2-proxy-homelab;

  # Genera la unit systemd para una instancia.
  mkInstance = name: inst:
    let
      # Wrapper script: lee secrets desde $CREDENTIALS_DIRECTORY (LoadCredential
      # los expone como files con permisos restringidos), exporta como env y
      # exec oauth2-proxy. Evita pasar secrets como CLI args (visibles en `ps`).
      startScript = pkgs.writeShellScript "oauth2-proxy-${name}-start" ''
        set -euo pipefail
        export OAUTH2_PROXY_CLIENT_SECRET=$(cat "$CREDENTIALS_DIRECTORY/client-secret")
        export OAUTH2_PROXY_COOKIE_SECRET=$(cat "$CREDENTIALS_DIRECTORY/cookie-secret")
        exec ${pkgs.oauth2-proxy}/bin/oauth2-proxy \
          --provider=keycloak-oidc \
          --oidc-issuer-url=${lib.escapeShellArg cfg.keycloakIssuer} \
          --client-id=${lib.escapeShellArg inst.clientId} \
          --scope=${lib.escapeShellArg "openid email profile"} \
          --email-domain=* \
          --http-address=${lib.escapeShellArg "127.0.0.1:${toString inst.listenPort}"} \
          --upstream=${lib.escapeShellArg inst.upstream} \
          --reverse-proxy=true \
          --cookie-secure=true \
          --cookie-name=${lib.escapeShellArg "_oauth2_proxy_${name}"} \
          --skip-provider-button=true \
          --pass-access-token=false \
          --pass-authorization-header=false \
          --set-xauthrequest=false \
          ${lib.concatMapStringsSep " "
            (d: "--whitelist-domain=" + lib.escapeShellArg d)
            inst.whitelistDomains}
      '';
    in
    lib.nameValuePair "oauth2-proxy-${name}" {
      description = "oauth2-proxy front for ${name} (KC realm homelab)";
      after    = [ "network-online.target" "keycloak.service" ];
      wants    = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        # LoadCredential maneja la lectura privilegiada: agenix coloca .path con
        # owner=root,mode=0400; systemd los copia a /run/credentials/<unit>/
        # accesible solo por la unit (DynamicUser-friendly).
        LoadCredential = [
          "client-secret:${config.age.secrets."oauth2ProxyClientSecret_${name}".path}"
          "cookie-secret:${config.age.secrets.oauth2ProxyCookieSecret.path}"
        ];
        ExecStart = "${startScript}";
        Restart = "on-failure";
        RestartSec = "5s";
        # Hardening estándar para procesos network-facing sin escritura local.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    };
in
{
  options.services.oauth2-proxy-homelab = {
    enable = lib.mkEnableOption ''
      oauth2-proxy multi-instance frente a servicios homelab sin OIDC nativo
      (D.4b). Cada instancia es un proceso systemd independiente vinculado a
      un client OIDC en el realm Keycloak homelab.
    '';

    keycloakIssuer = lib.mkOption {
      type = lib.types.str;
      default = "https://auth.mauricioantolin.com/realms/homelab";
      description = ''
        OIDC issuer URL del realm. oauth2-proxy hace discovery de endpoints
        (auth/token/userinfo/jwks) desde {issuer}/.well-known/openid-configuration.
      '';
    };

    cookieSecretFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path al .age con el cookie-secret (44-byte base64 de 32 bytes random).
        Compartido entre todas las instancias para simplificar rotación.
      '';
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          clientId = lib.mkOption {
            type = lib.types.str;
            default = "oauth2proxy-${name}";
            description = "Client ID en el realm Keycloak.";
          };
          clientSecretFile = lib.mkOption {
            type = lib.types.path;
            description = ''
              Path al .age con el client-secret OIDC para esta instancia.
              Cada instancia tiene su propio client + secret.
            '';
          };
          listenPort = lib.mkOption {
            type = lib.types.port;
            description = ''
              Puerto loopback (127.0.0.1) en el que oauth2-proxy escucha.
              Tailscale-serve y/o cloudflared apuntan acá, no al backend directo.
            '';
          };
          upstream = lib.mkOption {
            type = lib.types.str;
            example = "http://127.0.0.1:8989";
            description = ''
              URL del backend al que oauth2-proxy proxea tras autenticación.
              Loopback only — el backend confía en que X-Forwarded-* viene de un
              proxy local.
            '';
          };
          whitelistDomains = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "sonarr.mauricioantolin.com" ];
            description = ''
              Dominios permitidos como redirect target tras OIDC callback (además
              del request host actual). Necesario cuando el servicio se expone
              en múltiples hosts (TS Serve magic + CF Tunnel) y el redirect debe
              volver al host de origen, no al hardcodeado.
            '';
          };
        };
      }));
      default = { };
      description = ''
        Mapa <name> → instance config. El name forma el nombre de la systemd
        unit (oauth2-proxy-<name>) y default clientId (oauth2proxy-<name>).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Cookie secret compartido — registrado una vez.
    age.secrets.oauth2ProxyCookieSecret = {
      file = cfg.cookieSecretFile;
      owner = "root";
      group = "root";
      mode = "0400";
    };

    # Un age.secrets entry por instancia (key disambiguada por name).
    age.secrets = lib.mapAttrs'
      (name: inst: lib.nameValuePair "oauth2ProxyClientSecret_${name}" {
        file = inst.clientSecretFile;
        owner = "root";
        group = "root";
        mode = "0400";
      })
      cfg.instances;

    # Una systemd service por instancia.
    systemd.services = lib.mapAttrs' mkInstance cfg.instances;
  };
}
