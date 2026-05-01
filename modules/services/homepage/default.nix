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

    # Widget secrets bootstrap: oneshot que extrae API keys de cada servicio
    # (config files o vía API con admin pass) y las escribe en un EnvironmentFile
    # mode 0400 root:root que podman le inyecta como vars HOMEPAGE_VAR_*.
    # Los .yaml en /var/lib/homepage/config (mode 644) referencian las vars con
    # `{{HOMEPAGE_VAR_X}}` — los secrets nunca tocan disco persistente plaintext.
    secretsBootstrap = {
      enable = lib.mkEnableOption "Auto-extract widget secrets to EnvironmentFile";
      paperlessAdminPassPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path al .age con admin pass de Paperless (para POST /api/token/).";
      };
      grafanaAdminPassPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path al .age con admin pass de Grafana (basic auth en widget).";
      };
      delugeWebUiPassword = lib.mkOption {
        type = lib.types.str;
        default = "deluge";
        description = "Password WebUI Deluge (default 'deluge'; cambiar si se rota).";
      };
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
        PUID = "1000";
        PGID = "1000";
        HOSTNAME = "127.0.0.1";
      };
      # Widget secrets via env file generado por homepage-secrets-bootstrap.
      # Podman lee el archivo a startup; el container nunca lo ve en su filesystem.
      environmentFiles =
        lib.optional cfg.secretsBootstrap.enable
          "/run/homepage-secrets/env";
      volumes = [
        # /var/lib/homepage/config es un directorio escribible; los archivos se
        # copian allí en cada activación por el servicio homepage-config-sync.
        "/var/lib/homepage/config:/app/config"
        "/var/lib/homepage/icons:/app/public/icons"
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

    # ── Phase 8 — Widget secrets bootstrap ───────────────────────────────────
    # Extrae API keys/passes de servicios on-host y los expone como
    # HOMEPAGE_VAR_* en /run/homepage-secrets/env (root:root 0400).
    # Idempotente: comparemos hash → si cambió, restart container.
    systemd.services.homepage-secrets-bootstrap =
      lib.mkIf cfg.secretsBootstrap.enable {
        description = "Extract API keys + admin passes for Homepage widget env";
        wantedBy = [ "podman-homepage.service" ];
        before    = [ "podman-homepage.service" ];
        # Esperá a que cada servicio fuente esté arriba; si alguno no existe en
        # el sistema systemd lo ignora silenciosamente (no fail).
        after = [
          "sonarr.service"
          "radarr.service"
          "prowlarr.service"
          "bazarr.service"
          "deluge.service"
          "paperless-web.service"
          "grafana.service"
        ];
        path = with pkgs; [ curl jq coreutils gnugrep gawk libxml2 ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential =
            (lib.optional (cfg.secretsBootstrap.paperlessAdminPassPath != null)
              "paperless-pass:${toString cfg.secretsBootstrap.paperlessAdminPassPath}")
            ++ (lib.optional (cfg.secretsBootstrap.grafanaAdminPassPath != null)
              "grafana-pass:${toString cfg.secretsBootstrap.grafanaAdminPassPath}");
        };
        script = ''
          set -uo pipefail
          install -d -m 0700 /run/homepage-secrets

          extract_xml_apikey() {
            local f="$1"
            [ -r "$f" ] || return 0
            xmllint --xpath 'string(//ApiKey)' "$f" 2>/dev/null || true
          }
          extract_bazarr_apikey() {
            local f="$1"
            [ -r "$f" ] || return 0
            awk '/^auth:/{flag=1; next} /^[a-z]/{flag=0} flag && /apikey:/{print $2; exit}' "$f" 2>/dev/null || true
          }

          SONARR=$(extract_xml_apikey /var/lib/sonarr/config.xml)
          RADARR=$(extract_xml_apikey /var/lib/radarr/config.xml)
          # Prowlarr corre con DynamicUser → state en /var/lib/private/prowlarr.
          PROWLARR=$(extract_xml_apikey /var/lib/private/prowlarr/config.xml)
          BAZARR=$(extract_bazarr_apikey /var/lib/bazarr/config/config.yaml)

          # Paperless: POST /api/token/ con admin/pass (DRF obtain_auth_token,
          # idempotente — devuelve siempre el mismo token por user). Retry 6×5s
          # por si el unit acaba de arrancar.
          PAPERLESS_TOKEN=""
          if [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -r "$CREDENTIALS_DIRECTORY/paperless-pass" ]; then
            PAPERLESS_PASS=$(cat "$CREDENTIALS_DIRECTORY/paperless-pass")
            for i in 1 2 3 4 5 6; do
              PAPERLESS_TOKEN=$(curl -sf -m 5 -X POST -H 'Content-Type: application/json' \
                -d "{\"username\":\"admin\",\"password\":\"$PAPERLESS_PASS\"}" \
                http://127.0.0.1:8000/api/token/ 2>/dev/null | jq -r '.token // ""' 2>/dev/null || echo "")
              [ -n "$PAPERLESS_TOKEN" ] && break
              sleep 5
            done
          fi

          GRAFANA_PASS=""
          if [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -r "$CREDENTIALS_DIRECTORY/grafana-pass" ]; then
            GRAFANA_PASS=$(cat "$CREDENTIALS_DIRECTORY/grafana-pass")
          fi

          NEW=$(mktemp -p /run/homepage-secrets .env.XXXXXX)
          chmod 0400 "$NEW"
          cat > "$NEW" <<EOF
          HOMEPAGE_VAR_SONARR_KEY=$SONARR
          HOMEPAGE_VAR_RADARR_KEY=$RADARR
          HOMEPAGE_VAR_PROWLARR_KEY=$PROWLARR
          HOMEPAGE_VAR_BAZARR_KEY=$BAZARR
          HOMEPAGE_VAR_PAPERLESS_TOKEN=$PAPERLESS_TOKEN
          HOMEPAGE_VAR_GRAFANA_PASS=$GRAFANA_PASS
          HOMEPAGE_VAR_DELUGE_PASS=${cfg.secretsBootstrap.delugeWebUiPassword}
          EOF

          OUT=/run/homepage-secrets/env
          if [ ! -f "$OUT" ] || ! cmp -s "$NEW" "$OUT"; then
            mv -f "$NEW" "$OUT"
            # Restart pickup new env (podman bake env at container creation).
            systemctl try-restart podman-homepage.service 2>/dev/null || true
          else
            rm -f "$NEW"
          fi
        '';
      };
  };
}
