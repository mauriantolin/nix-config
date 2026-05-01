{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.paperless-homelab;
  secretsRoot = "${inputs.secrets}/secrets";
in
{
  options.services.paperless-homelab = {
    enable = lib.mkEnableOption "Paperless-ngx (gestión documental + OCR spa+eng)";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "paperless.mauricioantolin.com";
      description = "Hostname público que enruta cloudflared a Paperless.";
    };

    consumeDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/docs/consume";
      description = ''
        Directorio que paperless-consumer monitorea via inotify.
        Compartido vía Samba (`samba-homelab.shares.paperless-consume`) para drag-and-drop
        desde cualquier device del tailnet. consumptionDirIsPublic=true setea 0775 al dir.
      '';
    };

    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/docs/media";
      description = "Originales y archivos servidos. En tank (HDD).";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/paperless";
      description = "DB cache, tantivy search index, modelos clasificación. En rpool (SSD).";
    };

    ocrLanguage = lib.mkOption {
      type = lib.types.str;
      default = "spa+eng";
      description = "Lenguajes OCR (formato tesseract: lang1+lang2).";
    };

    timeZone = lib.mkOption {
      type = lib.types.str;
      default = "America/Argentina/Buenos_Aires";
    };

    oidc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Habilitar SSO via Keycloak (realm homelab, client `paperless`).
          Mantiene login local activo (PAPERLESS_DISABLE_REGULAR_LOGIN=false)
          hasta family onboarding — admin mauri sigue con user/pass local.
          allauth provider_id=keycloak → callback URI:
            https://<domain>/accounts/oidc/keycloak/login/callback/
        '';
      };
      issuerWellKnown = lib.mkOption {
        type = lib.types.str;
        default = "https://auth.mauricioantolin.com/realms/homelab/.well-known/openid-configuration";
      };
      clientId = lib.mkOption {
        type = lib.types.str;
        default = "paperless";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.paperless = {
      enable = true;
      address = "127.0.0.1";
      port = 8000;

      consumptionDir = cfg.consumeDir;
      consumptionDirIsPublic = true;   # 0775 → permite drop desde mauri vía Samba
      mediaDir = cfg.mediaDir;
      dataDir = cfg.dataDir;

      passwordFile = config.age.secrets.paperlessAdminPass.path;

      settings = {
        # Postgres (loopback, sin TLS)
        PAPERLESS_DBHOST = "127.0.0.1";
        PAPERLESS_DBPORT = 5432;
        PAPERLESS_DBNAME = "paperless";
        PAPERLESS_DBUSER = "paperless";
        # PAPERLESS_DBPASS viene via EnvironmentFile (ver paperless-db-env-prepare).
        PAPERLESS_DBSSLMODE = "disable";

        # OCR
        PAPERLESS_OCR_LANGUAGE = cfg.ocrLanguage;
        PAPERLESS_TIME_ZONE = cfg.timeZone;

        # CF Tunnel headers (cloudflared agrega X-Forwarded-*)
        PAPERLESS_URL = "https://${cfg.domain}";
        PAPERLESS_USE_X_FORWARD_HOST = true;
        PAPERLESS_USE_X_FORWARD_PORT = true;
        PAPERLESS_PROXY_SSL_HEADER = "[\"HTTP_X_FORWARDED_PROTO\", \"https\"]";
        PAPERLESS_TRUSTED_PROXIES = "127.0.0.1";

        # Workers: i5-4440 4C/4T (no HT). 2 workers + 1 thread = headroom para web/celery.
        PAPERLESS_TASK_WORKERS = 2;
        PAPERLESS_THREADS_PER_WORKER = 1;
        PAPERLESS_OCR_PAGES = 0;          # all pages

        # Filename storage human-readable
        PAPERLESS_FILENAME_FORMAT = "{created_year}/{correspondent}/{title}";

        # Ignorar artefactos de macOS / Windows en el consume dir
        PAPERLESS_CONSUMER_IGNORE_PATTERN = builtins.toJSON [
          ".DS_STORE/*"
          "._*"
          "desktop.ini"
          "Thumbs.db"
        ];

        # Redis local Unix socket dedicado a paperless
        PAPERLESS_REDIS = "unix:///run/redis-paperless/redis.sock";
      } // lib.optionalAttrs cfg.oidc.enable {
        # Registra el provider OIDC de allauth en INSTALLED_APPS de Django.
        # Sin esto, PAPERLESS_SOCIALACCOUNT_PROVIDERS se carga pero allauth no
        # registra las URLs /accounts/oidc/<provider_id>/login/ → redirect a
        # /accounts/login/?next=... en lugar del flow OIDC.
        PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
      };
    };

    # Django SECRET_KEY via LoadCredential en paperless-web (NixOS module no lo expone como
    # secretKeyFile en versiones <2.x; usar EnvironmentFile como fallback general).
    age.secrets.paperlessSecretKey = {
      file  = "${secretsRoot}/paperless-secret-key.age";
      owner = "paperless";
      group = "paperless";
      mode  = "0400";
    };

    age.secrets.paperlessAdminPass = {
      file  = "${secretsRoot}/paperless-admin-pass.age";
      owner = "paperless";
      group = "paperless";
      mode  = "0400";
    };

    # Postgres password agenix-encrypted, leído por oneshot prepare → env file consumido
    # por todos los systemd units de paperless. Workaround porque el módulo NixOS no expone
    # PAPERLESS_DBPASS_FILE (solo passwordFile=admin).
    age.secrets.postgresPaperlessPass = {
      file  = "${secretsRoot}/postgres-paperless-pass.age";
      owner = "paperless";
      group = "paperless";
      mode  = "0400";
    };

    # OIDC client secret (mismo .age que el bootstrap KC inyecta en el realm).
    # Se materializa en el env file rendered en runtime para que el JSON
    # PAPERLESS_SOCIALACCOUNT_PROVIDERS no quede world-readable en /nix/store.
    age.secrets.oidcClientPaperless = lib.mkIf cfg.oidc.enable {
      file  = "${secretsRoot}/oidc-client-paperless.age";
      owner = "paperless";
      group = "paperless";
      mode  = "0400";
    };

    systemd.services.paperless-db-env-prepare = {
      description = "Render PAPERLESS_DBPASS + (opcional) OIDC env file from agenix";
      after = [ "agenix.service" ];
      wantedBy = [ "paperless-web.service" ];
      before = [
        "paperless-web.service"
        "paperless-consumer.service"
        "paperless-scheduler.service"
        "paperless-task-queue.service"
      ];
      path = with pkgs; [ jq coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        umask 077
        install -d -m 0750 -o paperless -g paperless /run/paperless-env
        pass=$(cat ${config.age.secrets.postgresPaperlessPass.path})
        secret=$(cat ${config.age.secrets.paperlessSecretKey.path})
        ${lib.optionalString cfg.oidc.enable ''
          oidc_secret=$(cat ${config.age.secrets.oidcClientPaperless.path})
          # JSON shape esperado por allauth.socialaccount.providers.openid_connect.
          # Bash-quoting: jq construye el JSON, single-line para el env file.
          oidc_json=$(jq -nc \
            --arg client_id   "${cfg.oidc.clientId}" \
            --arg secret      "$oidc_secret" \
            --arg server_url  "${cfg.oidc.issuerWellKnown}" \
            '{
              openid_connect: {
                APPS: [{
                  provider_id: "keycloak",
                  name: "Keycloak",
                  client_id: $client_id,
                  secret: $secret,
                  settings: { server_url: $server_url }
                }],
                OAUTH_PKCE_ENABLED: true
              }
            }')
        ''}
        # systemd EnvironmentFile parsing: valores con `"` deben estar quoted.
        # JSON no contiene `'`, asi que single-quote wrap es seguro y simple.
        cat > /run/paperless-env/db.env <<EOF
        PAPERLESS_DBPASS=$pass
        PAPERLESS_SECRET_KEY=$secret
        ${lib.optionalString cfg.oidc.enable "PAPERLESS_SOCIALACCOUNT_PROVIDERS='$oidc_json'"}
        EOF
        chown paperless:paperless /run/paperless-env/db.env
        chmod 0400 /run/paperless-env/db.env
      '';
    };

    # Inyectar el env file en TODOS los units de paperless.
    systemd.services.paperless-web.serviceConfig.EnvironmentFile         = [ "/run/paperless-env/db.env" ];
    systemd.services.paperless-consumer.serviceConfig.EnvironmentFile    = [ "/run/paperless-env/db.env" ];
    systemd.services.paperless-scheduler.serviceConfig.EnvironmentFile   = [ "/run/paperless-env/db.env" ];
    systemd.services.paperless-task-queue.serviceConfig.EnvironmentFile  = [ "/run/paperless-env/db.env" ];

    # Paperless requires que postgres y redis estén UP antes de arrancar.
    systemd.services.paperless-web.after = [ "postgresql.service" "redis-paperless.service" "paperless-db-env-prepare.service" ];
    systemd.services.paperless-web.requires = [ "postgresql.service" "redis-paperless.service" "paperless-db-env-prepare.service" ];

    # Redis dedicado para paperless (Unix socket, sin TCP).
    services.redis.servers.paperless = {
      enable = true;
      user = "paperless";
      port = 0;   # 0 → Unix socket only
      unixSocket = "/run/redis-paperless/redis.sock";
      unixSocketPerm = 600;
    };

    # tank/docs subdirs.
    # IMPORTANTE: consumptionDirIsPublic=true del módulo nixpkgs crea consumeDir con 0777
    # SOLO si está en /var/lib/paperless. Cuando consumeDir es path externo (tank), hay que
    # declararlo explícito acá. Idem dataDir/{log,data,index}: cuando dataDir es dataset ZFS
    # nuevo (vacío post-creación), el módulo paperless asume que existen y falla con
    # PermissionError al loggear. Los pre-creamos.
    systemd.tmpfiles.rules = [
      "d /srv/docs              0755 paperless paperless -"
      "d ${cfg.consumeDir}      2775 paperless paperless -"   # setgid + group writable (mauri)
      "d ${cfg.mediaDir}        0755 paperless paperless -"
      "d /srv/docs/originals    0755 paperless paperless -"
      "d ${cfg.dataDir}         0755 paperless paperless -"
      "d ${cfg.dataDir}/log     0755 paperless paperless -"
      "d ${cfg.dataDir}/data    0755 paperless paperless -"
      "d ${cfg.dataDir}/index   0755 paperless paperless -"
    ];

    # mauri necesita estar en grupo paperless para escribir al consume dir vía Samba.
    # forceGroup=paperless en la samba share resolverá ownership de los archivos drop.
    users.users.mauri.extraGroups = [ "paperless" ];
  };
}
