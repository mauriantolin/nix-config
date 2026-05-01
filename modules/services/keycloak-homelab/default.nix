{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.keycloak-homelab;
  secretsRoot = "${inputs.secrets}/secrets";

  # OIDC clients del realm 'homelab'. clientId = key, agenix secret = value (.age).
  # Mantenelo en sync con clients[].clientId de realm-export.json.
  oidcClients = {
    vaultwarden                = "oidc-client-vaultwarden";
    paperless                  = "oidc-client-paperless";
    grafana                    = "oidc-client-grafana";
    jellyfin                   = "oidc-client-jellyfin";
    jellyseerr                 = "oidc-client-jellyseerr";
    "oauth2proxy-sonarr"       = "oidc-client-oauth2proxy-sonarr";
    "oauth2proxy-radarr"       = "oidc-client-oauth2proxy-radarr";
    "oauth2proxy-prowlarr"     = "oidc-client-oauth2proxy-prowlarr";
    "oauth2proxy-bazarr"       = "oidc-client-oauth2proxy-bazarr";
    "oauth2proxy-deluge"       = "oidc-client-oauth2proxy-deluge";
    "oauth2proxy-homepage"     = "oidc-client-oauth2proxy-homepage";
    "oauth2proxy-kuma"         = "oidc-client-oauth2proxy-kuma";
    "oauth2proxy-prometheus"   = "oidc-client-oauth2proxy-prometheus";
  };

  # Placeholder usado en initialAdminPassword. NixOS keycloak module exige string;
  # bootstrap lo reemplaza inmediatamente con el de agenix. Ventana de exposición:
  # solo loopback, segundos hasta que keycloak-bootstrap.service rota el password.
  adminPlaceholder = "BOOTSTRAP_PLACEHOLDER_X47Tq9_DO_NOT_USE";

in
{
  options.services.keycloak-homelab = {
    enable = lib.mkEnableOption "Keycloak SSO (Quarkus, postgres-shared backend, encrypted ZFS)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8180;
      description = "HTTP port. Loopback only — CF Tunnel + Tailscale Serve hacen reverse proxy.";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "auth.mauricioantolin.com";
      description = "FQDN público (CF Tunnel termina TLS).";
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "mauri";
      description = "Username del admin de master realm tras bootstrap.";
    };

    smtp = {
      enable = lib.mkEnableOption "SMTP (Google Workspace SMTP Relay) para password reset / verify email";
      host = lib.mkOption {
        type = lib.types.str;
        default = "smtp-relay.gmail.com";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 587;
      };
      username = lib.mkOption {
        type = lib.types.str;
        example = "mauri@mauricioantolin.com";
        description = ''
          Email del Workspace user al que pertenece el App Password.
          El SMTP relay autentica con ese user; el FROM puede ser cualquier
          alias Send-As configurado en él (ver cfg.smtp.from).
        '';
      };
      from = lib.mkOption {
        type = lib.types.str;
        default = "auth@mauricioantolin.com";
        description = ''
          FROM address. Debe estar configurado como Send-As alias en el user
          Workspace (Gmail → Settings → Accounts → "Send mail as"), sino el
          relay reescribe FROM al username real.
        '';
      };
      fromDisplayName = lib.mkOption {
        type = lib.types.str;
        default = "Homelab Auth";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ── agenix secrets ─────────────────────────────────────────────────────
    # Nix no acepta `age.secrets.X = ...` y `age.secrets = ...` en la misma
    # attrset literal (collision). Combinamos vía mkMerge para preservar la
    # condicionalidad de smtp con mkIf y para fusionar los OIDC clients.
    age.secrets = lib.mkMerge [
      {
        "keycloak-db-pass" = {
          file = "${secretsRoot}/keycloak-db-pass.age";
          owner = "keycloak";
          group = "keycloak";
          mode = "0400";
        };
        "keycloak-admin-pass" = {
          file = "${secretsRoot}/keycloak-admin-pass.age";
          owner = "keycloak";
          group = "keycloak";
          mode = "0400";
        };
      }
      (lib.mkIf cfg.smtp.enable {
        "keycloak-smtp-pass" = {
          file = "${secretsRoot}/keycloak-smtp-pass.age";
          owner = "keycloak";
          group = "keycloak";
          mode = "0400";
        };
      })
      # OIDC client secrets — value de oidcClients es el .age filename, lo usamos
      # también como key del age.secrets attr.
      (lib.mapAttrs'
        (clientName: secretFile: lib.nameValuePair secretFile {
          file = "${secretsRoot}/${secretFile}.age";
          owner = "keycloak";
          group = "keycloak";
          mode = "0400";
        })
        oidcClients)
    ];

    # ── Postgres DB (gestionado via postgres-shared-homelab) ───────────────
    services.postgres-shared-homelab.databases.keycloak = {
      user = "keycloak";
      secretFile = config.age.secrets."keycloak-db-pass".path;
    };

    # ── Keycloak service ───────────────────────────────────────────────────
    services.keycloak = {
      enable = true;

      database = {
        type = "postgresql";
        host = "127.0.0.1";
        port = 5432;
        useSSL = false;        # loopback
        createLocally = false; # postgres-shared maneja DB+user+pass
        username = "keycloak";
        passwordFile = config.age.secrets."keycloak-db-pass".path;
      };

      settings = {
        hostname = cfg.hostname;
        hostname-strict = true;
        # Keycloak 26 removió `proxy = "edge"`. Replacement oficial:
        # `proxy-headers = "xforwarded"` para que confíe en X-Forwarded-Proto/Host/For
        # del CF Tunnel (cloudflared inyecta ese set, no la cabecera RFC-7239 Forwarded).
        # Ref: https://www.keycloak.org/docs/latest/upgrading/index.html#proxy-option-removed
        proxy-headers = "xforwarded";
        http-enabled = true;
        http-host = "127.0.0.1";
        http-port = cfg.port;
        # Health + metrics endpoints sobre management interface por defecto :9000
        health-enabled = true;
        metrics-enabled = true;
      };

      # Placeholder mandatorio (el módulo NixOS lo exige). El bootstrap oneshot
      # rota el pass real ni bien Keycloak está READY. Bind 127.0.0.1 + ventana
      # de segundos = riesgo aceptable.
      initialAdminPassword = adminPlaceholder;
    };

    # keycloak.service debe esperar a que postgres-set-passwords haya seteado
    # el pass del user 'keycloak' (sino la primera connection falla con auth error
    # y Quarkus aborta tras 5min de retries → unit failed). `wants` = soft-dep:
    # si pg-set-passwords falla, keycloak.service entra en restart-loop hasta que
    # se estabilice (mejor que cascade-fail con `requires`).
    systemd.services.keycloak = {
      after = [ "postgres-set-passwords.service" ];
      wants = [ "postgres-set-passwords.service" ];
    };

    # ── Bootstrap oneshot ───────────────────────────────────────────────────
    # 1. Espera /health/ready
    # 2. Login con placeholder admin pass
    # 3. Rota pass del user 'admin' al real (agenix), opcionalmente renombra a cfg.adminUser
    # 4. Si el realm 'homelab' no existe, lo importa con secrets inyectados via jq
    systemd.services.keycloak-bootstrap = {
      description = "Rotate admin password + import realm 'homelab' (idempotent)";
      after = [ "keycloak.service" ];
      requires = [ "keycloak.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ curl jq coreutils gnused ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "30s";

        LoadCredential =
          [
            "admin-pass:${config.age.secrets."keycloak-admin-pass".path}"
            "realm-export:${./realm-export.json}"
          ]
          ++ lib.optional cfg.smtp.enable
            "smtp-pass:${config.age.secrets."keycloak-smtp-pass".path}"
          ++ lib.mapAttrsToList (clientName: secretFile:
            "oidc-${clientName}:${config.age.secrets.${secretFile}.path}"
          ) oidcClients;
      };

      environment = {
        KC_URL = "http://127.0.0.1:${toString cfg.port}";
        ADMIN_PLACEHOLDER = adminPlaceholder;
        ADMIN_USER = cfg.adminUser;
        SMTP_ENABLE = if cfg.smtp.enable then "1" else "0";
        SMTP_HOST = cfg.smtp.host;
        SMTP_PORT = toString cfg.smtp.port;
        SMTP_USER = cfg.smtp.username or "";
        SMTP_FROM = cfg.smtp.from;
        SMTP_FROM_DISPLAY = cfg.smtp.fromDisplayName;
        # Lista de OIDC client names (igual al order de LoadCredential)
        OIDC_CLIENTS = lib.concatStringsSep " " (lib.attrNames oidcClients);
      };

      script = ''
        set -euo pipefail

        # 1. Espera Keycloak READY (max 5 min)
        echo "[bootstrap] esperando Keycloak READY en $KC_URL/health/ready..."
        for i in $(seq 1 60); do
          if curl -sf -m 5 "$KC_URL/health/ready" >/dev/null 2>&1; then
            echo "[bootstrap] Keycloak READY"
            break
          fi
          if [ "$i" -eq 60 ]; then
            echo "[bootstrap] FATAL: Keycloak no ready tras 5 min" >&2
            exit 1
          fi
          sleep 5
        done

        ADMIN_PASS=$(cat "$CREDENTIALS_DIRECTORY/admin-pass")
        get_token() {
          local user="$1" pass="$2"
          curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
            -d "username=$user" --data-urlencode "password=$pass" \
            -d "grant_type=password&client_id=admin-cli" | jq -r .access_token
        }

        # 2. Detectá si el placeholder pass aún es válido (primera corrida)
        TOKEN=$(get_token admin "$ADMIN_PLACEHOLDER" 2>/dev/null || true)
        if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
          echo "[bootstrap] placeholder pass válido — rotando admin password"
          USER_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
            "$KC_URL/admin/realms/master/users?username=admin&exact=true" | jq -r '.[0].id')
          curl -sf -X PUT "$KC_URL/admin/realms/master/users/$USER_ID/reset-password" \
            -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
            -d "$(jq -n --arg pass "$ADMIN_PASS" \
                '{type:"password", value:$pass, temporary:false}')"
          # Rename admin → cfg.adminUser
          if [ "$ADMIN_USER" != "admin" ]; then
            curl -sf -X PUT "$KC_URL/admin/realms/master/users/$USER_ID" \
              -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
              -d "$(jq -n --arg u "$ADMIN_USER" '{username:$u}')"
            echo "[bootstrap] admin renombrado a '$ADMIN_USER'"
          fi
          # Re-token con la nueva pass + nuevo username
          TOKEN=$(get_token "$ADMIN_USER" "$ADMIN_PASS")
        else
          echo "[bootstrap] placeholder ya rotado, login con admin real"
          TOKEN=$(get_token "$ADMIN_USER" "$ADMIN_PASS")
        fi

        if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
          echo "[bootstrap] FATAL: no pude obtener admin token" >&2
          exit 1
        fi

        # 3. Realm import (idempotent: si existe, skip)
        if curl -sf -H "Authorization: Bearer $TOKEN" "$KC_URL/admin/realms/homelab" >/dev/null 2>&1; then
          echo "[bootstrap] realm 'homelab' ya existe, skip import"
        else
          echo "[bootstrap] importando realm 'homelab' con secrets inyectados"

          REALM_JSON=$(mktemp)
          trap 'rm -f $REALM_JSON' EXIT
          cp "$CREDENTIALS_DIRECTORY/realm-export" "$REALM_JSON"

          # 3a. sed inyecta OIDC client secrets (placeholder REPLACE_SECRET_<clientId>)
          # JSON values son strings hex/alnum sin caracteres especiales para sed (/, &, \)
          # gracias a `openssl rand -hex 32` en bootstrap-d3-secrets.sh, pero igual escapamos.
          for client in $OIDC_CLIENTS; do
            secret_val=$(cat "$CREDENTIALS_DIRECTORY/oidc-$client")
            secret_esc=$(printf '%s' "$secret_val" | sed -e 's/[\/&|]/\\&/g')
            sed -i "s|REPLACE_SECRET_$client|$secret_esc|g" "$REALM_JSON"
          done

          # 3b. SMTP fields + admin user via jq (typed JSON edits)
          if [ "$SMTP_ENABLE" = "1" ]; then
            smtp_pass_val=$(cat "$CREDENTIALS_DIRECTORY/smtp-pass")
          else
            smtp_pass_val=""
          fi

          jq \
            --arg host "$SMTP_HOST" --arg port "$SMTP_PORT" \
            --arg user "$SMTP_USER" --arg pass "$smtp_pass_val" \
            --arg from "$SMTP_FROM" --arg display "$SMTP_FROM_DISPLAY" \
            --arg admin "$ADMIN_USER" --arg email "$SMTP_FROM" '
            .smtpServer.host = $host
            | .smtpServer.port = $port
            | .smtpServer.user = $user
            | .smtpServer.password = $pass
            | .smtpServer.from = $from
            | .smtpServer.fromDisplayName = $display
            | .users = (.users | map(
                if .username == "REPLACE_AT_BOOTSTRAP"
                then .username = $admin | .email = $email
                else .
                end
              ))
            ' "$REALM_JSON" > "$REALM_JSON.merged"
          mv "$REALM_JSON.merged" "$REALM_JSON"

          # 3c. POST a /admin/realms
          curl -sf -X POST "$KC_URL/admin/realms" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            --data-binary @"$REALM_JSON"

          echo "[bootstrap] realm 'homelab' importado OK"
          rm -f "$REALM_JSON"

          # 3d. Set password del homelab/<adminUser> = mismo admin pass del master.
          # Idempotent: si user ya tiene pass, reset-password lo sobrescribe.
          USER_HOMELAB_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
            "$KC_URL/admin/realms/homelab/users?username=$ADMIN_USER&exact=true" | jq -r '.[0].id // empty')
          if [ -n "$USER_HOMELAB_ID" ]; then
            curl -sf -X PUT "$KC_URL/admin/realms/homelab/users/$USER_HOMELAB_ID/reset-password" \
              -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
              -d "$(jq -n --arg pass "$ADMIN_PASS" \
                  '{type:"password", value:$pass, temporary:false}')"
            echo "[bootstrap] password seteado para homelab/$ADMIN_USER"
          else
            echo "[bootstrap] WARN: user '$ADMIN_USER' no encontrado en realm homelab post-import"
          fi
        fi

        echo "[bootstrap] DONE"
      '';
    };

    # ── networking firewall: NO abrimos :8180 a interfaces externas ────────
    # Bind 127.0.0.1 ya bloquea LAN; CF Tunnel + Tailscale Serve son los únicos
    # path públicos. No tocamos networking.firewall.
  };
}
