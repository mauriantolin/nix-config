{ config, lib, pkgs, ... }:
let
  cfg = config.services.zfs-services-bootstrap;
in
{
  options.services.zfs-services-bootstrap = {
    enable = lib.mkEnableOption ''
      Auto-create de datasets ZFS para servicios homelab si faltan al boot.

      Defensa contra el escenario E.1 incident 2026-04-25: disko.nix declara datasets
      pero solo los crea en install fresh (nixos-anywhere). Para deploys que agregan
      datasets nuevos en un host ya instalado, hay que crearlos manual con `zfs create`
      antes del switch — sino fileSystems falla a montar y el sistema cae a emergency mode.

      Este módulo declara una systemd unit oneshot que corre antes de `local-fs.target`
      y crea cualquier dataset listado en `cfg.datasets` que no exista. Idempotente
      (skip si ya existe), seguro de re-correr.
    '';

    datasets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          recordsize = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "8K";
          };
          extraProperties = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "ZFS properties extra (e.g. compression, atime, etc.)";
          };
          # D.3 — soporte para datasets ZFS-encriptados (key vía agenix).
          # Si encrypted=true, el create incluye `-o encryption=aes-256-gcm
          # -o keyformat=raw -o keylocation=file://${encryptionKeyPath}` y
          # el script hace `zfs load-key` al boot si la key todavía no está cargada.
          # Requiere que el unit corra DESPUÉS de agenix.service (auto-añadido cuando
          # algún dataset declara encrypted=true).
          encrypted = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Si true, dataset es ZFS-encriptado y se hace load-key automático.";
          };
          encryptionKeyPath = lib.mkOption {
            # str (no path) porque /run/agenix/X es runtime path, no Nix store.
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Path al raw 32-byte key (típicamente /run/agenix/<keyname>).
              REQUIRED si encrypted=true. Pasalo como
              `config.age.secrets.<keyname>.path`.
            '';
            example = "/run/agenix/keycloakZfsKey";
          };
        };
      });
      default = { };
      description = ''
        Map of <full-dataset-path> → { recordsize?; extraProperties; encrypted?; encryptionKeyPath? }.
        mountpoint=legacy se setea siempre (todos los datasets del homelab usan
        fileSystems para mount). Pool y parent dataset deben existir.
      '';
      example = lib.literalExpression ''
        {
          "rpool/services/postgres-shared" = { recordsize = "8K"; };
          "rpool/services/paperless" = {};
          "tank/docs" = { recordsize = "1M"; };
          "rpool/services/keycloak" = {
            encrypted = true;
            encryptionKeyPath = "/run/agenix/keycloakZfsKey";
            extraProperties = { compression = "zstd-3"; };
          };
        }
      '';
    };

    beforeMounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Lista de unidades systemd mount que dependen de estos datasets.
        El servicio bootstrap corre `before` y `wantedBy` cada una.
        Hardcodeado en lugar de `local-fs.target` para evitar ordering cycle
        (zfs-import.target → bootstrap → local-fs.target → sysinit → zfs-import).
        Convención: `<path-with-dashes>.mount` (e.g., `/var/lib/X` → `var-lib-X.mount`).
      '';
      example = lib.literalExpression ''
        [ "var-lib-postgresql.mount" "var-lib-paperless.mount" "srv-docs.mount" ]
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.datasets != { }) {
    # Fail fast si se declara encrypted=true sin path
    assertions =
      lib.mapAttrsToList
        (ds: spec: {
          assertion = !spec.encrypted || spec.encryptionKeyPath != null;
          message = "zfs-services-bootstrap: dataset '${ds}' tiene encrypted=true pero encryptionKeyPath=null.";
        })
        cfg.datasets;

    systemd.services.zfs-services-bootstrap = {
      description = "Auto-create missing ZFS datasets for homelab services";
      # Corre DESPUÉS de imports + ANTES de los mount units específicos.
      # NO usar local-fs.target acá: causa ordering cycle con sysinit.target.
      # Si hay datasets encriptados, también esperamos a agenix (que poblá /run/agenix/*).
      # Lección 2026-04-27 (D.3 fail): usar `wants` (soft) en vez de `requires` (hard)
      # para agenix.service — si agenix tarda 1s extra, requires aborta el unit y mount
      # falla → emergency mode. wants + after permite que esperemos sin abortar.
      after = [ "zfs-import.target" ]
        ++ lib.optional (lib.any (x: x.encrypted) (lib.attrValues cfg.datasets)) "agenix.service";
      requires = [ "zfs-import.target" ];
      wants = lib.optional (lib.any (x: x.encrypted) (lib.attrValues cfg.datasets)) "agenix.service";
      before = cfg.beforeMounts;
      wantedBy = cfg.beforeMounts;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Restart on-failure permite recovery si encryption key todavía no se decryptó
        # (race agenix vs bootstrap). Reintentamos hasta 5 veces a 10s c/u.
        Restart = "on-failure";
        RestartSec = "10s";
        # CRITICAL: sin esto el systemd-default `After=sysinit.target` crea un
        # ordering cycle:
        #   local-fs.target → mount → bootstrap → sysinit.target → local-fs.target
        # systemd lo "rompe" eliminando un edge (warning + exit 4 en switch).
        # Sumando 2 mounts más en E.3 hizo el cycle más largo y rompió grafana.
        # Bootstrap solo depende de zfs-import.target → no necesita default deps.
        DefaultDependencies = false;
      };
      # Espera hasta 5 retries (50s) antes de declarar fallo definitivo.
      unitConfig = {
        StartLimitIntervalSec = "60s";
        StartLimitBurst = 5;
      };

      script =
        let
          mkCreate = ds: spec:
            let
              recordsizeArg = lib.optionalString (spec.recordsize != null)
                "-o recordsize=${spec.recordsize}";
              extraArgs = lib.concatStringsSep " "
                (lib.mapAttrsToList (k: v: "-o ${k}=${v}") spec.extraProperties);
              encArgs = lib.optionalString spec.encrypted (
                "-o encryption=aes-256-gcm "
                + "-o keyformat=raw "
                + "-o keylocation=file://${toString spec.encryptionKeyPath}"
              );
              # Espera hasta 30s a que el key file de agenix aparezca (defensa contra
              # race agenix vs bootstrap durante switch).
              waitForKey = lib.optionalString spec.encrypted ''
                for i in $(seq 1 30); do
                  if [ -s "${toString spec.encryptionKeyPath}" ]; then break; fi
                  echo "[zfs-services-bootstrap] esperando ${toString spec.encryptionKeyPath}... ($i/30)"
                  sleep 1
                done
                if [ ! -s "${toString spec.encryptionKeyPath}" ]; then
                  echo "[zfs-services-bootstrap] FATAL: ${toString spec.encryptionKeyPath} no existe tras 30s" >&2
                  exit 1
                fi
              '';
              loadKeyOnExisting = lib.optionalString spec.encrypted ''
                if ${pkgs.zfs}/bin/zfs get -H -o value keystatus "${ds}" 2>/dev/null | grep -q unavailable; then
                  echo "[zfs-services-bootstrap] loading key for ${ds}"
                  ${pkgs.zfs}/bin/zfs load-key "${ds}"
                fi
              '';
            in
            ''
              ${waitForKey}
              if ! ${pkgs.zfs}/bin/zfs list -H -o name "${ds}" >/dev/null 2>&1; then
                echo "[zfs-services-bootstrap] creating ${ds}"
                ${pkgs.zfs}/bin/zfs create \
                  -o mountpoint=legacy \
                  ${recordsizeArg} \
                  ${extraArgs} \
                  ${encArgs} \
                  "${ds}"
              else
                echo "[zfs-services-bootstrap] ${ds} already exists, skipping create"
              fi
              ${loadKeyOnExisting}
            '';
        in
        ''
          set -euo pipefail
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkCreate cfg.datasets)}
        '';
    };
  };
}
