{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.grafana-homelab;
  secretsRoot = "${inputs.secrets}/secrets";
in
{
  options.services.grafana-homelab = {
    enable = lib.mkEnableOption ''
      Grafana con backend Postgres compartido + provisioning declarativo
      (datasource Prometheus + dashboards JSON checked-in).
      Loopback only — exposure via Tailscale Serve en home-server.
    '';

    port = lib.mkOption {
      type = lib.types.port;
      default = 3030;
      description = "Puerto Grafana (loopback). 3030 evita conflicto con homepage:3000.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "home-server.tailee5654.ts.net";
      description = "Hostname externo (Tailscale magic hostname).";
    };

    rootUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://home-server.tailee5654.ts.net:3443/";
      description = ''
        Root URL pública. Tailscale Serve mapea https://...:3443 → :3030 loopback.
        Bug original (2026-04-25): subpath /grafana/ + serve_from_sub_path=true
        producía redirect loop 301 a sí mismo (Grafana detecta proto inconsistente
        detrás del TLS terminator). Plan B (puerto dedicado, root path) lo evita
        — mismo patrón que Kuma en :8443.
      '';
    };

    prometheusUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:9090";
      description = "URL del Prometheus para el datasource (loopback típico).";
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
    };
  };

  config = lib.mkIf cfg.enable {
    # Admin password: random base64-24 generado en bootstrap; user lo guarda en VW.
    age.secrets.grafanaAdminPass = {
      file  = "${secretsRoot}/grafana-admin-pass.age";
      owner = "grafana";
      group = "grafana";
      mode  = "0400";
    };

    # postgres-grafana-pass ya lo declara home-server/default.nix (lo comparte
    # con postgres-shared-homelab.databases.grafana). Acá lo re-aliasamos a
    # owner=grafana para que el unit grafana pueda leerlo.
    age.secrets.postgresGrafanaPassForGrafana = {
      file  = "${secretsRoot}/postgres-grafana-pass.age";
      owner = "grafana";
      group = "grafana";
      mode  = "0400";
    };

    services.grafana = {
      enable = true;

      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = cfg.port;
          domain = cfg.domain;
          root_url = cfg.rootUrl;
          # serve_from_sub_path REMOVIDO — usamos puerto dedicado (Plan B del spec).
          # Subpath + Tailscale Serve TLS-termination → redirect loop 301.
          serve_from_sub_path = false;
          enforce_domain = false;
        };

        # Backend postgres compartido (DB+user creados por postgres-shared-homelab E.1).
        # password_file: Grafana lee el path on-startup (no necesita renderizado externo).
        database = {
          type = "postgres";
          host = "127.0.0.1:5432";
          name = "grafana";
          user = "grafana";
          password = "$__file{${config.age.secrets.postgresGrafanaPassForGrafana.path}}";
          ssl_mode = "disable";
        };

        security = {
          admin_user = cfg.adminUser;
          admin_password = "$__file{${config.age.secrets.grafanaAdminPass.path}}";
          # Anti-frame para evitar clickjacking. Subpath embedding interno funciona OK.
          allow_embedding = false;
          cookie_secure = true;
          disable_gravatar = true;
        };

        users = {
          allow_sign_up = false;
          allow_org_create = false;
          auto_assign_org = true;
        };

        "auth.anonymous".enabled = false;

        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
        };

        # Provisioning paths (Grafana lee .yaml en estos dirs al arranque).
        # NixOS module por default arma /etc/grafana-provisioning con symlinks; nosotros
        # le pasamos los archivos directamente vía `provision`.
        log.level = "info";
      };

      # Provisioning declarativo: settings.apiVersion=1 + objetos inline.
      # Dashboards: provider apunta al dir del repo con los JSONs (Nix store path).
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              access = "proxy";
              url = cfg.prometheusUrl;
              isDefault = true;
              editable = false;
            }
          ];
        };
        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "homelab";
              orgId = 1;
              folder = "Homelab";
              type = "file";
              disableDeletion = false;
              updateIntervalSeconds = 30;
              allowUiUpdates = true;
              options = {
                path = "${./dashboards}";
                foldersFromFilesStructure = false;
              };
            }
          ];
        };
      };
    };

    # Grafana depende de postgres listo (DB grafana migrada al primer arranque)
    # y del oneshot que chowna el mountpoint del dataset.
    systemd.services.grafana.after = [
      "postgresql.service"
      "postgres-set-passwords.service"
      "var-lib-grafana.mount"
      "grafana-mount-prepare.service"
    ];
    systemd.services.grafana.requires = [
      "postgresql.service"
      "postgres-set-passwords.service"
      "var-lib-grafana.mount"
      "grafana-mount-prepare.service"
    ];

    # Chown post-mount: el dataset ZFS se monta con root:root 0755 (default mountpoint
    # legacy). systemd-tmpfiles corre at sysinit ANTES del mount, con lo que su rule
    # se aplica al dir subyacente y queda oculto. grafana-pre-start crea symlinks
    # como user grafana → falla con "permission denied".
    # Fix: oneshot que chmod+chown DESPUÉS del mount, antes de grafana.service.
    systemd.services.grafana-mount-prepare = {
      description = "Fix /var/lib/grafana ownership post-ZFS-mount";
      after = [ "var-lib-grafana.mount" ];
      requires = [ "var-lib-grafana.mount" ];
      before = [ "grafana.service" ];
      wantedBy = [ "grafana.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.coreutils}/bin/chown grafana:grafana /var/lib/grafana
        ${pkgs.coreutils}/bin/chmod 0750 /var/lib/grafana
      '';
    };
  };
}
