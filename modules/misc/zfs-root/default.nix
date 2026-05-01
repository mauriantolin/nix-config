{ config, lib, pkgs, ... }:
{
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  # hostId requerido por ZFS; debe ser único y estable por host.
  # Generado con: head -c4 /dev/urandom | od -A n -t x1 | tr -d ' '
  # Valor concreto se setea en el módulo del host, no acá (compartible entre hosts = catástrofe).

  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "weekly";
      pools = [ "rpool" "tank" ];
    };
    trim.enable = true;     # TRIM SSD (rpool)
    # autoSnapshot se configura cuando se active sanoid/syncoid en Fase C.
  };

  # Reserva antiOOM: si un pool se llena al 100%, ZFS deja de funcionar.
  # El refreservation en rpool/reserved y tank/reserved (ver disko.nix) es el airbag.
}
