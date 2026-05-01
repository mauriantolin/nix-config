{ config, lib, pkgs, ... }:
let
  cfg = config.services.prometheus-homelab;

  # Phase 7c — alert rules embebidas. Cubre tres familias:
  #  (1) blackbox-http: probe_success==0 por 5m → endpoint público caído.
  #  (2) up{job=~"keycloak|oauth2-proxy-.+"}: scrape down por 2m → loopback caído.
  #  (3) blackbox SSL: probe_ssl_earliest_cert_expiry < 14d → renovación CF cert.
  alertRulesFile = pkgs.writeText "homelab-alerts.rules.yml" (builtins.toJSON {
    groups = [
      {
        name = "blackbox";
        rules = [
          {
            alert = "BlackboxProbeFailed";
            expr = "probe_success == 0";
            for = "5m";
            labels = { severity = "critical"; };
            annotations = {
              summary = "{{ $labels.instance }} probe failed";
              description = "Blackbox probe falló por 5 minutos para {{ $labels.instance }}.";
            };
          }
          {
            alert = "BlackboxSlowProbe";
            expr = "probe_duration_seconds > 3";
            for = "10m";
            labels = { severity = "warning"; };
            annotations = {
              summary = "{{ $labels.instance }} responde lento (>3s)";
              description = "probe_duration_seconds={{ $value }}s sustained 10m.";
            };
          }
          {
            alert = "BlackboxSslExpiringSoon";
            expr = "probe_ssl_earliest_cert_expiry - time() < 86400 * 14";
            for = "1h";
            labels = { severity = "warning"; };
            annotations = {
              summary = "{{ $labels.instance }} TLS cert expira en <14d";
              description = "Cloudflare suele rotar a tiempo, pero verificar.";
            };
          }
        ];
      }
      {
        name = "sso-scrape";
        rules = [
          {
            alert = "ScrapeTargetDown";
            expr = "up{job=~\"keycloak|oauth2-proxy-.+\"} == 0";
            for = "2m";
            labels = { severity = "critical"; };
            annotations = {
              summary = "{{ $labels.job }} (instance {{ $labels.instance }}) DOWN";
              description = "Prometheus no puede scrapear {{ $labels.job }} hace 2m.";
            };
          }
        ];
      }
      {
        name = "node";
        rules = [
          {
            alert = "DiskAlmostFull";
            expr = "(1 - node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes) > 0.90";
            for = "10m";
            labels = { severity = "warning"; };
            annotations = {
              summary = "{{ $labels.mountpoint }} >90% lleno";
              description = "Filesystem {{ $labels.mountpoint }} usage={{ $value | humanizePercentage }}.";
            };
          }
          {
            alert = "DiskCritical";
            expr = "(1 - node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes) > 0.95";
            for = "5m";
            labels = { severity = "critical"; };
            annotations = {
              summary = "{{ $labels.mountpoint }} >95% lleno";
              description = "Filesystem {{ $labels.mountpoint }} usage={{ $value | humanizePercentage }}.";
            };
          }
        ];
      }
    ];
  });

  # Blackbox modules: HTTP probes (estándar 2xx + POST) + TCP + ICMP.
  # YAML embedido para evitar archivo separado en el repo.
  blackboxConfig = pkgs.writeText "blackbox.yml" (builtins.toJSON {
    modules = {
      http_2xx = {
        prober = "http";
        timeout = "5s";
        http = {
          method = "GET";
          preferred_ip_protocol = "ip4";
          fail_if_not_ssl = false;
          valid_http_versions = [ "HTTP/1.1" "HTTP/2.0" ];
          # 200: vault, paperless, whoami, cal sin auth
          # 302: oauth2-proxy redirect a KC + KC redirect a /realms/master
          # 401: WWW-Authenticate challenge (radicale)
          # 403: CF Access pre-auth si políticas cambian (ruidoso pero != down)
          valid_status_codes = [ 200 302 401 403 ];
        };
      };
      http_post_2xx = {
        prober = "http";
        timeout = "5s";
        http = {
          method = "POST";
          preferred_ip_protocol = "ip4";
        };
      };
      tcp_connect = {
        prober = "tcp";
        timeout = "5s";
      };
      icmp = {
        prober = "icmp";
        timeout = "5s";
      };
    };
  });
in
{
  options.services.prometheus-homelab = {
    enable = lib.mkEnableOption ''
      Prometheus + exporters base (node, blackbox, postgres) para observabilidad
      del homelab. Loopback only — exposure via Tailscale Serve en home-server.
    '';

    port = lib.mkOption {
      type = lib.types.port;
      default = 9090;
      description = "Puerto Prometheus (loopback only).";
    };

    retention = lib.mkOption {
      type = lib.types.str;
      default = "30d";
      example = "14d";
      description = ''
        Retention TSDB. 30d ~ 1-3 GB con ~5 targets @ 15s.
        Bajar si /var/lib/prometheus se llena.
      '';
    };

    externalUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:9090";
      description = "URL pública usada en links (alerts, federation).";
    };

    scrapeInterval = lib.mkOption {
      type = lib.types.str;
      default = "15s";
      description = "Default scrape interval.";
    };

    scrapeTargets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            example = "127.0.0.1:8000";
            description = "host:port (sin esquema) del target.";
          };
          metricsPath = lib.mkOption {
            type = lib.types.str;
            default = "/metrics";
            description = "Path del endpoint Prometheus en el target.";
          };
          scheme = lib.mkOption {
            type = lib.types.enum [ "http" "https" ];
            default = "http";
          };
          interval = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Override scrape interval (null → usa default).";
          };
        };
      });
      default = { };
      description = ''
        Apps con endpoint /metrics propio. Nombre del attr → job_name.
        Para sumar targets cuando llega E.2/E.4 simplemente extender este attrset.
      '';
      example = lib.literalExpression ''
        {
          paperless = { url = "127.0.0.1:8000"; metricsPath = "/metrics"; };
          jellyfin  = { url = "127.0.0.1:8096"; };
        }
      '';
    };

    blackboxTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        URLs HTTPS a probar con módulo http_2xx. Útil para alerting de
        endpoints públicos (vault.*, paperless.*, whoami.*).
      '';
      example = lib.literalExpression ''
        [ "https://vault.mauricioantolin.com" "https://paperless.mauricioantolin.com" ]
      '';
    };

    nodeExporterPort = lib.mkOption {
      type = lib.types.port;
      default = 9100;
    };
    blackboxExporterPort = lib.mkOption {
      type = lib.types.port;
      default = 9115;
    };
    postgresExporterPort = lib.mkOption {
      type = lib.types.port;
      default = 9187;
    };

    # Phase 7c — alertmanager + SMTP notifier. Sólo se activa si enable=true.
    # Reusa el mismo Workspace SMTP relay que Keycloak (smtp-relay.gmail.com:587
    # autenticado como admin@mauricioantolin.com con App Password en agenix).
    alertmanager = {
      enable = lib.mkEnableOption ''
        Alertmanager loopback :9093 + email notifier vía Google Workspace SMTP relay.
        Carga reglas de alerta default (blackbox, sso scrape, node disk).
      '';
      port = lib.mkOption {
        type = lib.types.port;
        default = 9093;
      };
      smtpHost = lib.mkOption {
        type = lib.types.str;
        default = "smtp-relay.gmail.com";
      };
      smtpPort = lib.mkOption {
        type = lib.types.port;
        default = 587;
      };
      smtpUsername = lib.mkOption {
        type = lib.types.str;
        example = "admin@mauricioantolin.com";
        description = ''
          Workspace user que autentica el relay (App Password en passwordFile).
        '';
      };
      smtpFrom = lib.mkOption {
        type = lib.types.str;
        example = "alerts@mauricioantolin.com";
        description = "From address (debe ser alias Send-As del username).";
      };
      smtpTo = lib.mkOption {
        type = lib.types.str;
        example = "suscripciones@mauricioantolin.com";
        description = "Destinatario de las alertas.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path al .age con el App Password del SMTP relay.";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # ── Exporters ─────────────────────────────────────────────────────────────
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.nodeExporterPort;
      # Collectors: foco en CPU/RAM/disk/red/ZFS + systemd unit health.
      enabledCollectors = [
        "systemd"
        "zfs"
        "filesystem"
        "loadavg"
        "meminfo"
        "cpu"
        "diskstats"
        "netdev"
        "netstat"
        "uname"
        "vmstat"
        "stat"
      ];
      # Excluir mounts virtuales (tmpfs, overlay, etc.) del filesystem collector.
      extraFlags = [
        "--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs|tmpfs)$"
      ];
    };

    services.prometheus.exporters.blackbox = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.blackboxExporterPort;
      configFile = blackboxConfig;
    };

    # postgres-exporter conecta vía Unix socket peer auth como user `postgres`.
    # Patrón limpio que evita guardar password adicional para monitoring.
    services.prometheus.exporters.postgres = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.postgresExporterPort;
      runAsLocalSuperUser = true;
    };

    # ── Prometheus ────────────────────────────────────────────────────────────
    services.prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.port;
      retentionTime = cfg.retention;
      webExternalUrl = cfg.externalUrl;

      # Phase 7c — wire prometheus → alertmanager (loopback) + load rule file.
      ruleFiles = lib.optional cfg.alertmanager.enable alertRulesFile;
      alertmanagers = lib.optional cfg.alertmanager.enable {
        static_configs = [
          { targets = [ "127.0.0.1:${toString cfg.alertmanager.port}" ]; }
        ];
      };

      globalConfig = {
        scrape_interval = cfg.scrapeInterval;
        evaluation_interval = cfg.scrapeInterval;
      };

      scrapeConfigs = [
        # Self-scrape
        {
          job_name = "prometheus";
          static_configs = [
            { targets = [ "127.0.0.1:${toString cfg.port}" ]; }
          ];
        }
        # Node
        {
          job_name = "node";
          static_configs = [
            { targets = [ "127.0.0.1:${toString cfg.nodeExporterPort}" ]; }
          ];
        }
        # Postgres
        {
          job_name = "postgres";
          static_configs = [
            { targets = [ "127.0.0.1:${toString cfg.postgresExporterPort}" ]; }
          ];
        }
      ]
      ++ (lib.mapAttrsToList
        (name: spec: {
          job_name = name;
          metrics_path = spec.metricsPath;
          scheme = spec.scheme;
          static_configs = [ { targets = [ spec.url ]; } ];
        } // lib.optionalAttrs (spec.interval != null) {
          scrape_interval = spec.interval;
        })
        cfg.scrapeTargets)
      ++ lib.optionals (cfg.blackboxTargets != [ ]) [
        # Blackbox: relabel pattern oficial — el target real va en __param_target,
        # y el address de scrape se reescribe al exporter.
        {
          job_name = "blackbox-http";
          metrics_path = "/probe";
          scrape_interval = "60s";
          params = { module = [ "http_2xx" ]; };
          static_configs = [ { targets = cfg.blackboxTargets; } ];
          relabel_configs = [
            { source_labels = [ "__address__" ]; target_label = "__param_target"; }
            { source_labels = [ "__param_target" ]; target_label = "instance"; }
            {
              target_label = "__address__";
              replacement = "127.0.0.1:${toString cfg.blackboxExporterPort}";
            }
          ];
        }
      ];
    };

    # ── Storage ───────────────────────────────────────────────────────────────
    # NixOS prometheus module usa stateDir=prometheus2 → /var/lib/prometheus2.
    # systemd StateDirectory=prometheus2 chowna automáticamente al user prometheus
    # cuando el path existe (nuestro mount lo crea con root:root, systemd lo arregla).
    # Sumamos `after` explícito para que el TSDB no escriba antes del mount.
    systemd.services.prometheus.after = [ "var-lib-prometheus2.mount" ];
    systemd.services.prometheus.requires = [ "var-lib-prometheus2.mount" ];

    # postgres-exporter depende de postgres (peer auth → socket disponible).
    systemd.services.prometheus-postgres-exporter.after = [ "postgresql.service" ];
    systemd.services.prometheus-postgres-exporter.requires = [ "postgresql.service" ];

    # ── Phase 7c — Alertmanager ───────────────────────────────────────────────
    # Loopback only :9093, SMTP password vía agenix con owner=alertmanager.
    age.secrets = lib.mkIf cfg.alertmanager.enable {
      alertmanagerSmtpPass = {
        file  = cfg.alertmanager.passwordFile;
        owner = "alertmanager";
        group = "alertmanager";
        mode  = "0400";
      };
    };

    services.prometheus.alertmanager = lib.mkIf cfg.alertmanager.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.alertmanager.port;
      configuration = {
        global = {
          smtp_smarthost = "${cfg.alertmanager.smtpHost}:${toString cfg.alertmanager.smtpPort}";
          smtp_from = cfg.alertmanager.smtpFrom;
          smtp_auth_username = cfg.alertmanager.smtpUsername;
          # password_file: Alertmanager 0.27+ lee el path on startup, evita meter el
          # secret en el config rendered (que termina en /nix/store world-readable).
          smtp_auth_password_file =
            config.age.secrets.alertmanagerSmtpPass.path;
          smtp_require_tls = true;
          resolve_timeout = "5m";
        };
        route = {
          # group_by por alertname + instance: una notificación por endpoint, no
          # un mail por probe ciclado. group_wait=30s da tiempo a varios fires
          # simultáneos (ej. CF Tunnel cae → 6 hostnames flap a la vez).
          group_by = [ "alertname" "instance" ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "12h";
          receiver = "email-default";
        };
        receivers = [
          {
            name = "email-default";
            email_configs = [
              {
                to = cfg.alertmanager.smtpTo;
                send_resolved = true;
              }
            ];
          }
        ];
      };
    };

    # Alertmanager corre como user `alertmanager` (nixos default). Necesita
    # leer el .age — owner ya seteado arriba.
    systemd.services.alertmanager =
      lib.mkIf cfg.alertmanager.enable {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };
  };
}
