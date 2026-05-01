{ config, lib, pkgs, ... }:
let
  cfg = config.services.jellyseerr-homelab;
in
{
  options.services.jellyseerr-homelab = {
    enable = lib.mkEnableOption ''
      Jellyseerr — UI de requests para Jellyfin/Sonarr/Radarr.

      Acceso público vía CF Tunnel (requests.mauricioantolin.com) con CF Access
      en BYPASS (auth interna de Jellyseerr usando Jellyfin como provider OAuth).
      OTP rompería UX para family sin email-en-allowlist.
    '';

    port = lib.mkOption {
      type = lib.types.port;
      default = 5055;
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "requests.mauricioantolin.com";
    };

    jellyfinUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8096";
      description = "URL interna de Jellyfin (auth provider).";
    };

    autoBootstrap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Si true, oneshot post-start configura Jellyseerr via API:
        - Marca initialized=true (skip wizard)
        - Configura Jellyfin como auth provider
        - Conecta Sonarr (read API key de /var/lib/sonarr/config.xml)
        - Conecta Radarr (idem)

        Idempotente: chequea /api/v1/settings/main.initialized antes de aplicar.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.jellyseerr = {
      enable = true;
      port = cfg.port;
      openFirewall = false;
    };

    # Bind 0.0.0.0 para que sea accesible vía Tailnet (home-server:5055). El
    # firewall sólo abre el puerto en tailscale0, así que LAN/WAN no lo ven.
    # Acceso público externo va por CF Tunnel → 127.0.0.1:5055 (loopback igual).
    systemd.services.jellyseerr.environment = {
      HOST = "0.0.0.0";
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];

    # NOTA: jellyseerr en NixOS 25.11 usa DynamicUser=yes + StateDirectory=jellyseerr.
    # systemd gestiona /var/lib/jellyseerr (symlink → /var/lib/private/jellyseerr) y
    # se rehúsa si pre-existe como dir real (ej: dataset ZFS montado). Por eso NO
    # tenemos dataset dedicado en disko.nix — vive en rpool/var (pocos KB).

    # ── Auto-bootstrap ───────────────────────────────────────────────────────
    # Jellyseerr API endpoints relevantes:
    #   POST /api/v1/auth/jellyfin       (login con admin Jellyfin → session cookie)
    #   POST /api/v1/settings/jellyfin   (configura el server Jellyfin)
    #   POST /api/v1/settings/sonarr     (agrega Sonarr server)
    #   POST /api/v1/settings/radarr     (agrega Radarr server)
    #   POST /api/v1/settings/initialize (marca wizard done)
    systemd.services.jellyseerr-bootstrap = lib.mkIf cfg.autoBootstrap {
      description = "Wire Jellyseerr ↔ Jellyfin/Sonarr/Radarr via API";
      after = [
        "jellyseerr.service"
        "jellyfin-bootstrap.service"   # admin user existe
        "arr-bootstrap.service"        # API keys de Sonarr/Radarr existen
      ];
      requires = [ "jellyseerr.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ curl jq libxml2 coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "30s";
        LoadCredential = [
          "jellyfin-admin-pass:${config.age.secrets.jellyfinAdminPass.path}"
        ];
      };
      script = ''
        set -euo pipefail

        JS=http://127.0.0.1:${toString cfg.port}
        JF=${cfg.jellyfinUrl}
        ADMIN=mauri
        JF_PASS=$(cat "$CREDENTIALS_DIRECTORY/jellyfin-admin-pass")
        COOKIES=$(mktemp); trap "rm -f $COOKIES" EXIT

        # Esperar a Jellyseerr healthy
        for i in $(seq 1 60); do
          curl -sf "$JS/api/v1/status" >/dev/null && break
          sleep 2
        done

        # Idempotency: si initialized=true, skip
        INIT=$(curl -sf "$JS/api/v1/settings/public" | jq -r .initialized 2>/dev/null || echo false)
        if [ "$INIT" = "true" ]; then
          echo "[bootstrap] Jellyseerr ya inicializado — skip"
          exit 0
        fi

        # Step 1: login con Jellyfin admin (crea session cookie)
        echo "[bootstrap] login con Jellyfin admin..."
        LOGIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
          -c "$COOKIES" \
          -X POST -H 'Content-Type: application/json' \
          "$JS/api/v1/auth/jellyfin" \
          -d "{\"username\":\"$ADMIN\",\"password\":\"$JF_PASS\",\"hostname\":\"$JF\",\"email\":\"$ADMIN@local\"}")
        if [ "$LOGIN_CODE" != "200" ] && [ "$LOGIN_CODE" != "201" ]; then
          echo "[bootstrap] login falló HTTP $LOGIN_CODE" >&2
          exit 1
        fi

        # Step 2: configurar Jellyfin server settings
        echo "[bootstrap] configurando Jellyfin server..."
        curl -sf -b "$COOKIES" -c "$COOKIES" \
          -X POST -H 'Content-Type: application/json' \
          "$JS/api/v1/settings/jellyfin" \
          -d "{\"name\":\"Jellyfin\",\"hostname\":\"127.0.0.1\",\"port\":8096,\"useSsl\":false,\"urlBase\":\"\",\"externalHostname\":\"$JF\"}" \
          >/dev/null || echo "[bootstrap] settings/jellyfin POST warning (continúo)"

        # Step 3: extraer API keys de *arr y agregarlos
        SONARR_KEY=$(xmllint --xpath 'string(//ApiKey)' /var/lib/sonarr/config.xml 2>/dev/null || echo "")
        RADARR_KEY=$(xmllint --xpath 'string(//ApiKey)' /var/lib/radarr/config.xml 2>/dev/null || echo "")

        if [ -n "$SONARR_KEY" ]; then
          echo "[bootstrap] agregando Sonarr..."
          curl -sf -b "$COOKIES" -c "$COOKIES" \
            -X POST -H 'Content-Type: application/json' \
            "$JS/api/v1/settings/sonarr" \
            -d @- <<JSON || echo "[bootstrap] settings/sonarr warning"
{
  "name": "Sonarr",
  "hostname": "127.0.0.1",
  "port": 8989,
  "apiKey": "$SONARR_KEY",
  "useSsl": false,
  "baseUrl": "",
  "activeProfileId": 1,
  "activeLanguageProfileId": 1,
  "activeAnimeProfileId": 1,
  "activeAnimeLanguageProfileId": 1,
  "activeDirectory": "/srv/storage/media/tv",
  "activeAnimeDirectory": "/srv/storage/media/tv",
  "is4k": false,
  "isDefault": true,
  "enableSeasonFolders": true,
  "syncEnabled": true
}
JSON
        else
          echo "[bootstrap] SONARR_KEY no disponible — skip"
        fi

        if [ -n "$RADARR_KEY" ]; then
          echo "[bootstrap] agregando Radarr..."
          curl -sf -b "$COOKIES" -c "$COOKIES" \
            -X POST -H 'Content-Type: application/json' \
            "$JS/api/v1/settings/radarr" \
            -d @- <<JSON || echo "[bootstrap] settings/radarr warning"
{
  "name": "Radarr",
  "hostname": "127.0.0.1",
  "port": 7878,
  "apiKey": "$RADARR_KEY",
  "useSsl": false,
  "baseUrl": "",
  "activeProfileId": 1,
  "activeDirectory": "/srv/storage/media/movies",
  "is4k": false,
  "isDefault": true,
  "minimumAvailability": "released",
  "syncEnabled": true
}
JSON
        else
          echo "[bootstrap] RADARR_KEY no disponible — skip"
        fi

        # Step 4: marcar wizard completado
        echo "[bootstrap] finalizando setup..."
        curl -sf -b "$COOKIES" -c "$COOKIES" \
          -X POST -H 'Content-Type: application/json' \
          "$JS/api/v1/settings/initialize" \
          -d '{}' >/dev/null || echo "[bootstrap] initialize POST warning"

        echo "[bootstrap] Jellyseerr OK"
      '';
    };
  };
}
