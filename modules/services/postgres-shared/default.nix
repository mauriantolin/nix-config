{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.postgres-shared-homelab;
  secretsRoot = "${inputs.secrets}/secrets";
  pkg = pkgs.postgresql_16;
in
{
  options.services.postgres-shared-homelab = {
    enable = lib.mkEnableOption "Shared PostgreSQL 16 instance for homelab services (loopback only)";

    databases = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          user = lib.mkOption {
            type = lib.types.str;
            description = "Postgres role that owns this DB.";
          };
          secretFile = lib.mkOption {
            type = lib.types.path;
            description = ''
              Path al .age con el password en texto plano del role.
              El módulo lo lee via systemd LoadCredential y lo aplica con ALTER USER
              en cada start de postgresql.service (idempotente, sobrevive rotación).
            '';
          };
        };
      });
      default = { };
      description = ''
        Map de <dbname> → { user; secretFile }. Cada DB se crea con el user como OWNER.
        Si en el futuro un servicio quiere DB compartida (raro), se puede usar
        ensureDBOwnership=false manualmente.
      '';
    };

    backupDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/backups/postgresql";
      description = "Destino de postgresqlBackup (Q4 spec E.1: tank/backups/postgresql).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      package = pkg;
      dataDir = "/var/lib/postgresql/${pkg.psqlSchema}";

      enableTCPIP = true;
      settings = {
        # Loopback ONLY — sin exposure a Tailscale ni LAN. Conexiones same-host.
        listen_addresses = lib.mkForce "127.0.0.1";
        port = 5432;
        password_encryption = "scram-sha-256";

        # Tuning baseline para 8 GB RAM. Re-tunear post upgrade RAM (i5-4440 → 24/32 GB).
        shared_buffers = "256MB";
        work_mem = "16MB";
        maintenance_work_mem = "64MB";
        effective_cache_size = "2GB";
        wal_compression = "on";

        # Logs útiles sin spam (queries lentas + connection events).
        log_min_duration_statement = "1s";
        log_connections = "on";
        log_disconnections = "off";
      };

      # peer auth para postgres (admin local), scram para el resto.
      # mkOverride 10 sobreescribe el default de NixOS (que usa md5).
      authentication = lib.mkOverride 10 ''
        # TYPE  DATABASE    USER         ADDRESS         METHOD
        local   all         postgres                     peer
        local   all         all                          scram-sha-256
        host    all         all          127.0.0.1/32    scram-sha-256
        host    all         all          ::1/128         scram-sha-256
      '';

      ensureDatabases = lib.attrNames cfg.databases;
      ensureUsers = lib.mapAttrsToList (db: spec: {
        name = spec.user;
        ensureDBOwnership = true;   # match user==dbname → user es OWNER
      }) cfg.databases;
    };

    # Post-start: aplica ALTER USER PASSWORD para todos los users desde agenix.
    # Razón: services.postgresql.ensureUsers crea users SIN password (gotcha NixOS conocido).
    # LoadCredential copia los .age desencriptados a un tmpfs solo legible por este unit.
    # SQL injection guard: usamos dollar-quoted strings de Postgres ($tag$...$tag$) —
    # el password va literal sin necesidad de escape de comillas. Tag `bspw` (bootstrap pw)
    # minimiza colisión; openssl rand -base64 nunca genera ese substring.
    #
    # Lección 2026-04-27 (D.3 deploy): cuando agregamos un nuevo DB/user (keycloak),
    # ensureUsers se ejecuta en `postgresql-setup.service`, que arranca en paralelo a
    # nosotros. Si nuestro ALTER USER corre primero, ERROR "role does not exist".
    # Defensa:
    #   1) `wants + after = postgresql-setup.service` — esperamos su completion.
    #   2) Por cada user, polleamos pg_roles hasta 60s antes de ALTER (idempotente,
    #      cubre incluso si setup-service no existe en otra distro).
    #   3) Restart=on-failure por si todo falla → reintenta al estabilizarse postgres.
    systemd.services.postgres-set-passwords = {
      description = "Sync postgres user passwords from agenix";
      after = [ "postgresql.service" "postgresql-setup.service" ];
      requires = [ "postgresql.service" ];
      wants = [ "postgresql-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Restart = "on-failure";
        RestartSec = "10s";
        LoadCredential = lib.mapAttrsToList
          (db: spec: "${spec.user}:${toString spec.secretFile}")
          cfg.databases;
      };
      unitConfig = {
        StartLimitIntervalSec = "120s";
        StartLimitBurst = 6;
      };
      script = ''
        set -euo pipefail

        # Espera hasta 30s a que postgres acepte conexiones por socket.
        for i in $(seq 1 30); do
          ${pkg}/bin/pg_isready -h /run/postgresql -q && break
          sleep 1
        done

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (db: spec: ''
          # User ${spec.user} → DB ${db}
          # Espera hasta 60s a que el role exista (race con postgresql-setup ensureUsers)
          for i in $(seq 1 60); do
            exists=$(${pkg}/bin/psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${spec.user}'" || true)
            if [ "$exists" = "1" ]; then break; fi
            echo "[wait] role ${spec.user} aún no existe ($i/60)"
            sleep 1
          done
          raw=$(cat "$CREDENTIALS_DIRECTORY/${spec.user}")
          ${pkg}/bin/psql -v ON_ERROR_STOP=1 -tAc \
            "ALTER USER \"${spec.user}\" WITH PASSWORD \$bspw\$$raw\$bspw\$;"
          echo "[OK] password set for role ${spec.user}"
        '') cfg.databases)}
      '';
    };

    # Backup declarativo: dump diario zstd-9 a tank/backups/postgresql.
    # 03:00 local — sanoid corre 04:00 (orden, snapshots ven dump fresco).
    services.postgresqlBackup = {
      enable = true;
      databases = lib.attrNames cfg.databases;
      compression = "zstd";
      compressionLevel = 9;
      location = cfg.backupDir;
      startAt = "*-*-* 03:00:00";
    };

    # Asegurar ownership del dir backup post-mount-ZFS.
    # tmpfiles corre antes de postgresql.service.
    systemd.tmpfiles.rules = [
      "d ${cfg.backupDir} 0700 postgres postgres -"
    ];
  };
}
