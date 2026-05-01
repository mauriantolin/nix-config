{ config, lib, pkgs, ... }:
let
  cfg = config.services.prometheus-homelab;

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
          valid_status_codes = [ ];   # default: 2xx
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
  };
}
