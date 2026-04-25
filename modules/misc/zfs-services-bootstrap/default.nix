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
        };
      });
      default = { };
      description = ''
        Map of <full-dataset-path> → { recordsize?; extraProperties }.
        mountpoint=legacy se setea siempre (todos los datasets del homelab usan
        fileSystems para mount). Pool y parent dataset deben existir.
      '';
      example = lib.literalExpression ''
        {
          "rpool/services/postgres-shared" = { recordsize = "8K"; };
          "rpool/services/paperless" = {};
          "tank/docs" = { recordsize = "1M"; };
        }
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.datasets != { }) {
    systemd.services.zfs-services-bootstrap = {
      description = "Auto-create missing ZFS datasets for homelab services";
      # Tiene que correr DESPUÉS de imports + ANTES de cualquier intento de mount.
      after = [ "zfs-import.target" ];
      requires = [ "zfs-import.target" ];
      before = [ "local-fs.target" "zfs-mount.service" ];
      wantedBy = [ "local-fs.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script =
        let
          mkCreate = ds: spec:
            let
              recordsizeArg = lib.optionalString (spec.recordsize != null)
                "-o recordsize=${spec.recordsize}";
              extraArgs = lib.concatStringsSep " "
                (lib.mapAttrsToList (k: v: "-o ${k}=${v}") spec.extraProperties);
            in
            ''
              if ! ${pkgs.zfs}/bin/zfs list -H -o name "${ds}" >/dev/null 2>&1; then
                echo "[zfs-services-bootstrap] creating ${ds}"
                ${pkgs.zfs}/bin/zfs create \
                  -o mountpoint=legacy \
                  ${recordsizeArg} \
                  ${extraArgs} \
                  "${ds}"
              else
                echo "[zfs-services-bootstrap] ${ds} already exists, skipping"
              fi
            '';
        in
        ''
          set -euo pipefail
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkCreate cfg.datasets)}
        '';
    };
  };
}
