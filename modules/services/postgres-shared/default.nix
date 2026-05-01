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
    # SQL injection guard: doblamos comillas simples en el password antes de inyectar.
    systemd.services.postgres-set-passwords = {
      description = "Sync postgres user passwords from agenix";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        LoadCredential = lib.mapAttrsToList
          (db: spec: "${spec.user}:${toString spec.secretFile}")
          cfg.databases;
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
          raw=$(cat "$CREDENTIALS_DIRECTORY/${spec.user}")
          # Escape ' → '' (PostgreSQL string literal escape) por defensa-en-profundidad.
          # En la práctica openssl rand -base64 no genera comillas, pero el escape protege
          # contra futuros generators o passwords manuales.
          # Nix indented-string: ''' renderiza a '' literal en el shell.
          escaped=$(printf '%s' "$raw" | ${pkgs.gnused}/bin/sed "s/'/'''/g")
          ${pkg}/bin/psql -v ON_ERROR_STOP=1 -tAc \
            "ALTER USER \"${spec.user}\" WITH PASSWORD '$escaped';"
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
