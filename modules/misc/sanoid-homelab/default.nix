# Sanoid local snapshot policy — Phase 7a.
#
# Tres tiers según valor + tasa de cambio del dataset:
# - critical:  servicios cuya pérdida implica re-bootstrap manual o pérdida
#              de credenciales/users (keycloak, vaultwarden, postgres, paperless).
#              Hourly 24 / Daily 30 / Weekly 12 / Monthly 6.
# - standard:  config de servicios reproducible vía deploy pero con state
#              acumulativo (jellyfin watch state, *arr DB, kuma history).
#              Hourly 12 / Daily 14 / Weekly 4 / Monthly 3.
# - media:     libraries grandes y de baja tasa de cambio (movies/tv/music,
#              docs paperless). Daily 7 / Weekly 4 / Monthly 0 (snapshots viejos
#              consumen mucho espacio si las series rotan).
#
# Datasets explícitamente fuera (no snapshot):
# - rpool/services/jellyfin-cache: transcode cache, volátil OK.
# - tank/downloads: torrents in-flight, churn alto.
{ config, lib, pkgs, ... }:
{
  config = {
    services.sanoid = {
      enable = true;

      # Templates: políticas reusables entre datasets.
      templates = {
        critical = {
          hourly = 24;
          daily = 30;
          weekly = 12;
          monthly = 6;
          autosnap = true;
          autoprune = true;
        };
        standard = {
          hourly = 12;
          daily = 14;
          weekly = 4;
          monthly = 3;
          autosnap = true;
          autoprune = true;
        };
        media = {
          hourly = 0;
          daily = 7;
          weekly = 4;
          monthly = 0;
          autosnap = true;
          autoprune = true;
        };
      };

      datasets = {
        # ── critical (auth/credentials/DB) ─────────────────────────────────
        "rpool/services/keycloak"        = { useTemplate = [ "critical" ]; };
        "rpool/services/vaultwarden"     = { useTemplate = [ "critical" ]; };
        "rpool/services/postgres-shared" = { useTemplate = [ "critical" ]; };
        "rpool/services/paperless"       = { useTemplate = [ "critical" ]; };
        "rpool/services/radicale"        = { useTemplate = [ "critical" ]; };

        # ── standard (config + state acumulativo) ──────────────────────────
        "rpool/services/jellyfin"        = { useTemplate = [ "standard" ]; };
        "rpool/services/sonarr"          = { useTemplate = [ "standard" ]; };
        "rpool/services/radarr"          = { useTemplate = [ "standard" ]; };
        "rpool/services/bazarr"          = { useTemplate = [ "standard" ]; };
        "rpool/services/deluge"          = { useTemplate = [ "standard" ]; };
        "rpool/services/uptime-kuma"     = { useTemplate = [ "standard" ]; };
        "rpool/services/homepage"        = { useTemplate = [ "standard" ]; };
        "rpool/services/grafana"         = { useTemplate = [ "standard" ]; };
        "rpool/services/prometheus"      = { useTemplate = [ "standard" ]; };

        # ── media (large, low-churn) ──────────────────────────────────────
        "tank/docs"                      = { useTemplate = [ "critical" ]; }; # paperless storage = critical
        "tank/storage/media/movies"      = { useTemplate = [ "media" ]; };
        "tank/storage/media/tv"          = { useTemplate = [ "media" ]; };
        "tank/storage/media/music"       = { useTemplate = [ "media" ]; };
      };
    };

    # Sanoid corre via systemd timer (default cada 5 min, sample new state).
    # NixOS también maneja el path al binary sanoid + dependencias zfs.
  };
}
