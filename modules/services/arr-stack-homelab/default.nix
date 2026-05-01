{ config, lib, pkgs, ... }:
let
  cfg = config.services.arr-stack-homelab;
in
{
  options.services.arr-stack-homelab = {
    enable = lib.mkEnableOption ''
      *arr stack: Prowlarr (indexers), Sonarr (TV), Radarr (movies), Bazarr (subs).
      Loopback only — exposure via Tailscale Serve en home-server (puertos nativos).

      Group `media` compartido (declarado por jellyfin-homelab) → permite hardlinks
      atómicos desde /srv/downloads/complete (deluge) → /srv/storage/media/{tv,movies}.

      Auto-bootstrap: oneshot post-start lee API keys de config.xml de cada *arr,
      configura Prowlarr applications (Sonarr+Radarr), Sonarr/Radarr download
      clients (Deluge) y root folders, Bazarr connections.
    '';

    prowlarrPort = lib.mkOption { type = lib.types.port; default = 9696; };
    sonarrPort   = lib.mkOption { type = lib.types.port; default = 8989; };
    radarrPort   = lib.mkOption { type = lib.types.port; default = 7878; };
    bazarrPort   = lib.mkOption { type = lib.types.port; default = 6767; };

    tvRoot = lib.mkOption {
      type = lib.types.path;
      default = "/srv/storage/media/tv";
    };
    moviesRoot = lib.mkOption {
      type = lib.types.path;
      default = "/srv/storage/media/movies";
    };
    musicRoot = lib.mkOption {
      type = lib.types.path;
      default = "/srv/storage/media/music";
    };
    downloadsCompleteRoot = lib.mkOption {
      type = lib.types.path;
      default = "/srv/downloads/complete";
      description = "Path donde *arr poll-importa torrents finalizados de Deluge.";
    };

    autoBootstrap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Si true, corre arr-bootstrap.service (oneshot idempotente) que conecta:
          Prowlarr ← Sonarr (api/v1/applications)
          Prowlarr ← Radarr (api/v1/applications)
          Sonarr → Deluge download client + TV root folder
          Radarr → Deluge download client + Movies root folder
          Bazarr ← Sonarr + Radarr connections
        Reqs: deluge corriendo, jellyfin user existente (para grupo media), agenix
        delugeWebPass disponible.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Group media ya viene declarado por jellyfin-homelab; los users *arr lo joinean.
    # Si E.2a no está activo, lo declaramos acá tmb como safeguard.
    users.groups.media = { };

    # ── Servicios *arr ──────────────────────────────────────────────────────
    services.prowlarr = {
      enable = true;
      openFirewall = false;
      # NixOS prowlarr module no expone group/dataDir directamente; usa
      # /var/lib/prowlarr fijo. Le forzamos group via systemd override más abajo.
    };

    services.sonarr = {
      enable = true;
      group = "media";
      dataDir = "/var/lib/sonarr";
      openFirewall = false;
    };

    services.radarr = {
      enable = true;
      group = "media";
      dataDir = "/var/lib/radarr";
      openFirewall = false;
    };

    services.bazarr = {
      enable = true;
      group = "media";
      openFirewall = false;
    };

    # Loopback bind: NixOS *arr modules NO exponen --bind-addr; bindean 0.0.0.0
    # por default. Mitigation: firewall solo abre estos ports en tailscale0
    # (servicio = loopback + tailscale, no LAN).
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
      cfg.prowlarrPort
      cfg.sonarrPort
      cfg.radarrPort
      cfg.bazarrPort
    ];

    # ── Storage prepare per-service ────────────────────────────────────────
    # Mismo patrón que jellyfin-storage-prepare: chown post-mount-ZFS antes
    # del start del servicio (tmpfiles at sysinit no sirve para datasets nuevos).
    # NOTA: prowlarr usa DynamicUser=yes en NixOS 25.11 (StateDirectory=prowlarr),
    # entonces NO pre-creamos /var/lib/prowlarr — systemd lo gestiona automáticamente
    # via /var/lib/private/prowlarr + symlink. Mismo razón por la cual prowlarr no
    # tiene dataset ZFS dedicado en disko.nix (queda en rpool/var, ~5 MB OK).
    systemd.services.arr-storage-prepare = {
      description = "Fix *arr dataDirs ownership post-ZFS-mount (sonarr/radarr/bazarr)";
      after = [
        "var-lib-sonarr.mount"
        "var-lib-radarr.mount"
        "var-lib-bazarr.mount"
      ];
      requires = [
        "var-lib-sonarr.mount"
        "var-lib-radarr.mount"
        "var-lib-bazarr.mount"
      ];
      before = [
        "sonarr.service"
        "radarr.service"
        "bazarr.service"
      ];
      wantedBy = [
        "sonarr.service"
        "radarr.service"
        "bazarr.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.coreutils}/bin/chown sonarr:media /var/lib/sonarr
        ${pkgs.coreutils}/bin/chmod 0750         /var/lib/sonarr
        ${pkgs.coreutils}/bin/chown radarr:media /var/lib/radarr
        ${pkgs.coreutils}/bin/chmod 0750         /var/lib/radarr
        ${pkgs.coreutils}/bin/chown bazarr:media /var/lib/bazarr
        ${pkgs.coreutils}/bin/chmod 0750         /var/lib/bazarr
      '';
    };

    # ── Auto-bootstrap (declarativo via API) ─────────────────────────────────
    systemd.services.arr-bootstrap = lib.mkIf cfg.autoBootstrap {
      description = "Wire *arr integrations (Prowlarr↔Sonarr/Radarr, Sonarr/Radarr→Deluge, Bazarr↔Sonarr/Radarr)";
      after = [
        "sonarr.service"
        "radarr.service"
        "prowlarr.service"
        "bazarr.service"
        "deluged.service"
      ];
      requires = [
        "sonarr.service"
        "radarr.service"
        "prowlarr.service"
        "bazarr.service"
      ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ curl jq libxml2 coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Re-correr en cada deploy es OK porque cada step es idempotente
        # (chequea existencia antes de crear).
        Restart = "on-failure";
        RestartSec = "30s";
        # Acceso al deluge auth file para sacar la pass para el download client config.
        LoadCredential = "deluge-pass:${config.age.secrets.delugeWebPass.path}";
      };
      script = ''
        # NixOS prepende `set -e` a serviceConfig.script — lo disable explícito.
        # Bootstrap es best-effort: cada step API-side puede fallar (schema mismatch
        # entre *arr versions) sin romper el deploy.
        set +e
        set -uo pipefail

        DELUGE_PASS=$(cat "$CREDENTIALS_DIRECTORY/deluge-pass")

        # ─── helpers ───────────────────────────────────────────────────────
        # Wait for an *arr service URL to respond on its API key endpoint.
        wait_arr() {
          local name="$1"; local url="$2"; local key="$3"
          for i in $(seq 1 60); do
            CODE=$(curl -s -o /dev/null -w "%{http_code}" \
              -H "X-Api-Key: $key" "$url/api/v3/system/status" || echo 000)
            if [ "$CODE" = "200" ]; then echo "[bootstrap] $name ready"; return 0; fi
            sleep 2
          done
          echo "[bootstrap] $name no respondió en 120s" >&2
          return 1
        }

        # Read API key from <dataDir>/config.xml (Sonarr/Radarr/Prowlarr usan XML)
        read_xml_key() {
          local file="$1"
          xmllint --xpath 'string(//ApiKey)' "$file" 2>/dev/null
        }

        # Read API key from Bazarr config.yaml
        read_bazarr_key() {
          local file="$1"
          # Bazarr stores api_key in config/config.yaml under auth.apikey or similar
          grep -E '^\s*apikey:' "$file" 2>/dev/null | head -1 | awk -F'[:"]' '{print $3}' | tr -d ' "'
        }

        # ─── extract API keys ──────────────────────────────────────────────
        echo "[bootstrap] extracting API keys..."

        for f in /var/lib/sonarr/config.xml /var/lib/radarr/config.xml /var/lib/prowlarr/config.xml; do
          for i in $(seq 1 30); do
            [ -f "$f" ] && break
            sleep 2
          done
          [ -f "$f" ] || { echo "[bootstrap] $f no aparece" >&2; exit 1; }
        done

        SONARR_KEY=$(read_xml_key /var/lib/sonarr/config.xml)
        RADARR_KEY=$(read_xml_key /var/lib/radarr/config.xml)
        PROWLARR_KEY=$(read_xml_key /var/lib/prowlarr/config.xml)

        [ -n "$SONARR_KEY" ]   || { echo "[bootstrap] no SONARR_KEY"   >&2; exit 1; }
        [ -n "$RADARR_KEY" ]   || { echo "[bootstrap] no RADARR_KEY"   >&2; exit 1; }
        [ -n "$PROWLARR_KEY" ] || { echo "[bootstrap] no PROWLARR_KEY" >&2; exit 1; }

        SONARR_URL=http://127.0.0.1:${toString cfg.sonarrPort}
        RADARR_URL=http://127.0.0.1:${toString cfg.radarrPort}
        PROWLARR_URL=http://127.0.0.1:${toString cfg.prowlarrPort}
        BAZARR_URL=http://127.0.0.1:${toString cfg.bazarrPort}

        wait_arr "Sonarr"   "$SONARR_URL"   "$SONARR_KEY"
        wait_arr "Radarr"   "$RADARR_URL"   "$RADARR_KEY"
        # Prowlarr usa /api/v1
        for i in $(seq 1 60); do
          CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "X-Api-Key: $PROWLARR_KEY" "$PROWLARR_URL/api/v1/system/status")
          [ "$CODE" = "200" ] && break
          sleep 2
        done

        # ─── Sonarr: root folder + download client ─────────────────────────
        echo "[bootstrap] Sonarr: root folder + Deluge"
        # Idempotent: skip si ya existe path
        EXISTING_ROOTS=$(curl -sf -H "X-Api-Key: $SONARR_KEY" "$SONARR_URL/api/v3/rootfolder")
        if ! echo "$EXISTING_ROOTS" | jq -e ".[] | select(.path==\"${cfg.tvRoot}\")" >/dev/null; then
          curl -sf -X POST -H "X-Api-Key: $SONARR_KEY" -H 'Content-Type: application/json' \
            "$SONARR_URL/api/v3/rootfolder" \
            -d "{\"path\":\"${cfg.tvRoot}\",\"name\":\"TV\",\"defaultTags\":[]}"
          echo "[bootstrap] Sonarr root folder ${cfg.tvRoot} agregado"
        else
          echo "[bootstrap] Sonarr root folder ${cfg.tvRoot} ya existía"
        fi

        EXISTING_DC=$(curl -sf -H "X-Api-Key: $SONARR_KEY" "$SONARR_URL/api/v3/downloadclient")
        if ! echo "$EXISTING_DC" | jq -e '.[] | select(.name=="Deluge")' >/dev/null; then
          curl -sf -X POST -H "X-Api-Key: $SONARR_KEY" -H 'Content-Type: application/json' \
            "$SONARR_URL/api/v3/downloadclient" -d @- <<JSON
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "Deluge",
  "fields": [
    {"name":"host","value":"127.0.0.1"},
    {"name":"port","value":${toString config.services.deluge-homelab.webPort}},
    {"name":"useSsl","value":false},
    {"name":"urlBase","value":""},
    {"name":"password","value":"$DELUGE_PASS"},
    {"name":"tvCategory","value":"tv-sonarr"},
    {"name":"tvImportedCategory","value":""},
    {"name":"recentTvPriority","value":0},
    {"name":"olderTvPriority","value":0},
    {"name":"addPaused","value":false}
  ],
  "implementationName": "Deluge",
  "implementation": "Deluge",
  "configContract": "DelugeSettings",
  "tags": []
}
JSON
          echo "[bootstrap] Sonarr download client Deluge agregado"
        else
          echo "[bootstrap] Sonarr download client Deluge ya existía"
        fi

        # ─── Radarr: root folder + download client ─────────────────────────
        echo "[bootstrap] Radarr: root folder + Deluge"
        EXISTING_ROOTS=$(curl -sf -H "X-Api-Key: $RADARR_KEY" "$RADARR_URL/api/v3/rootfolder")
        if ! echo "$EXISTING_ROOTS" | jq -e ".[] | select(.path==\"${cfg.moviesRoot}\")" >/dev/null; then
          curl -sf -X POST -H "X-Api-Key: $RADARR_KEY" -H 'Content-Type: application/json' \
            "$RADARR_URL/api/v3/rootfolder" \
            -d "{\"path\":\"${cfg.moviesRoot}\",\"name\":\"Movies\",\"defaultTags\":[]}"
          echo "[bootstrap] Radarr root folder ${cfg.moviesRoot} agregado"
        else
          echo "[bootstrap] Radarr root folder ${cfg.moviesRoot} ya existía"
        fi

        EXISTING_DC=$(curl -sf -H "X-Api-Key: $RADARR_KEY" "$RADARR_URL/api/v3/downloadclient")
        if ! echo "$EXISTING_DC" | jq -e '.[] | select(.name=="Deluge")' >/dev/null; then
          curl -sf -X POST -H "X-Api-Key: $RADARR_KEY" -H 'Content-Type: application/json' \
            "$RADARR_URL/api/v3/downloadclient" -d @- <<JSON
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "Deluge",
  "fields": [
    {"name":"host","value":"127.0.0.1"},
    {"name":"port","value":${toString config.services.deluge-homelab.webPort}},
    {"name":"useSsl","value":false},
    {"name":"urlBase","value":""},
    {"name":"password","value":"$DELUGE_PASS"},
    {"name":"movieCategory","value":"movies-radarr"},
    {"name":"movieImportedCategory","value":""},
    {"name":"recentMoviePriority","value":0},
    {"name":"olderMoviePriority","value":0},
    {"name":"addPaused","value":false}
  ],
  "implementationName": "Deluge",
  "implementation": "Deluge",
  "configContract": "DelugeSettings",
  "tags": []
}
JSON
          echo "[bootstrap] Radarr download client Deluge agregado"
        else
          echo "[bootstrap] Radarr download client Deluge ya existía"
        fi

        # ─── Prowlarr: applications (Sonarr + Radarr) ──────────────────────
        echo "[bootstrap] Prowlarr: applications"
        EXISTING_APPS=$(curl -sf -H "X-Api-Key: $PROWLARR_KEY" "$PROWLARR_URL/api/v1/applications")

        if ! echo "$EXISTING_APPS" | jq -e '.[] | select(.name=="Sonarr")' >/dev/null; then
          curl -sf -X POST -H "X-Api-Key: $PROWLARR_KEY" -H 'Content-Type: application/json' \
            "$PROWLARR_URL/api/v1/applications" -d @- <<JSON
{
  "name": "Sonarr",
  "syncLevel": "fullSync",
  "implementation": "Sonarr",
  "implementationName": "Sonarr",
  "configContract": "SonarrSettings",
  "fields": [
    {"name":"baseUrl","value":"$SONARR_URL"},
    {"name":"prowlarrUrl","value":"$PROWLARR_URL"},
    {"name":"apiKey","value":"$SONARR_KEY"},
    {"name":"syncCategories","value":[5000,5010,5020,5030,5040,5045,5050]}
  ],
  "tags": []
}
JSON
          echo "[bootstrap] Prowlarr↔Sonarr conectado"
        else
          echo "[bootstrap] Prowlarr↔Sonarr ya existía"
        fi

        if ! echo "$EXISTING_APPS" | jq -e '.[] | select(.name=="Radarr")' >/dev/null; then
          curl -sf -X POST -H "X-Api-Key: $PROWLARR_KEY" -H 'Content-Type: application/json' \
            "$PROWLARR_URL/api/v1/applications" -d @- <<JSON
{
  "name": "Radarr",
  "syncLevel": "fullSync",
  "implementation": "Radarr",
  "implementationName": "Radarr",
  "configContract": "RadarrSettings",
  "fields": [
    {"name":"baseUrl","value":"$RADARR_URL"},
    {"name":"prowlarrUrl","value":"$PROWLARR_URL"},
    {"name":"apiKey","value":"$RADARR_KEY"},
    {"name":"syncCategories","value":[2000,2010,2020,2030,2040,2045,2050,2060]}
  ],
  "tags": []
}
JSON
          echo "[bootstrap] Prowlarr↔Radarr conectado"
        else
          echo "[bootstrap] Prowlarr↔Radarr ya existía"
        fi

        # ─── Bazarr: connections (Sonarr + Radarr) ─────────────────────────
        # Bazarr API auth: X-API-KEY header con key del config.yaml.
        # Bazarr stores keys in /var/lib/bazarr/config/config.yaml (newer) or
        # /var/lib/bazarr/data/config/config.yaml (older). Lo busca dinámicamente.
        echo "[bootstrap] Bazarr: connections"
        BAZARR_CFG=""
        for c in /var/lib/bazarr/config/config.yaml /var/lib/bazarr/data/config/config.yaml; do
          [ -f "$c" ] && BAZARR_CFG="$c" && break
        done

        if [ -n "$BAZARR_CFG" ]; then
          BAZARR_KEY=$(read_bazarr_key "$BAZARR_CFG")
          if [ -n "$BAZARR_KEY" ]; then
            # POST settings via Bazarr API (system/settings endpoint)
            # Bazarr's API for settings is finicky; usamos PATCH al config endpoint.
            # Para evitar romper config existente, idempotency check via current config.
            CURRENT=$(curl -sf -H "X-API-KEY: $BAZARR_KEY" "$BAZARR_URL/api/system/settings" || echo "{}")
            HAS_SONARR=$(echo "$CURRENT" | jq -r '.sonarr.apikey // empty')
            HAS_RADARR=$(echo "$CURRENT" | jq -r '.radarr.apikey // empty')

            if [ "$HAS_SONARR" != "$SONARR_KEY" ] || [ "$HAS_RADARR" != "$RADARR_KEY" ]; then
              curl -sf -X POST -H "X-API-KEY: $BAZARR_KEY" -H 'Content-Type: application/json' \
                "$BAZARR_URL/api/system/settings" -d @- <<JSON || echo "[bootstrap] Bazarr settings POST falló (ignored, configurar manualmente)"
{
  "general": {"use_sonarr": true, "use_radarr": true},
  "sonarr": {
    "ip": "127.0.0.1", "port": ${toString cfg.sonarrPort}, "base_url": "/",
    "ssl": false, "apikey": "$SONARR_KEY",
    "full_update": "Daily", "only_monitored": false
  },
  "radarr": {
    "ip": "127.0.0.1", "port": ${toString cfg.radarrPort}, "base_url": "/",
    "ssl": false, "apikey": "$RADARR_KEY",
    "full_update": "Daily", "only_monitored": false
  }
}
JSON
              echo "[bootstrap] Bazarr conexiones Sonarr+Radarr aplicadas"
            else
              echo "[bootstrap] Bazarr conexiones ya configuradas"
            fi
          else
            echo "[bootstrap] Bazarr API key no encontrada en $BAZARR_CFG — configurar manualmente via UI"
          fi
        else
          echo "[bootstrap] Bazarr config.yaml no encontrado aún — re-correr arr-bootstrap luego del primer login"
        fi

        echo "[bootstrap] arr-stack OK"
      '';
    };
  };
}
