let
  # User pubkey — la misma que autorizamos para SSH en authorizedKeys, usada para editar secretos
  # desde la PC del user con `agenix -e`.
  mauricio = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM0/mKSFJ9hlyypK0uf3n55WDh/TCVWP8Rbbv9HAQl/q mauriantolin5@gmail.com";

  # Host pubkey — la ed25519 del home-server nuevo. Generada en Task 2.3.
  homeServer = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINUKK/LQTrCtgAfZcE054PqcgwKO+w8uMTZXpRkQEYrO root@home-server-nixos";

  users = [ mauricio ];
  systems = [ homeServer ];
in
{
  "tailscale-authkey.age".publicKeys = users ++ systems;
  "mauri-hashed-password.age".publicKeys = users ++ systems;
  "hello-secret.age".publicKeys = users ++ systems;

  # Fase B — ingress público via Cloudflare Tunnel
  "cloudflared-credentials.age".publicKeys = users ++ systems;
  "cloudflare-api-token.age".publicKeys = users ++ systems;

  # Fase C.1 — admin token Vaultwarden (env-file format con ADMIN_TOKEN=...)
  "vaultwarden-admin-token.age".publicKeys = users ++ systems;

  # Fase C.2 — Samba password usuario mauri
  "smb-mauri-password.age".publicKeys = users ++ systems;

  # Fase E.1 — Postgres compartido + apps E.1
  "postgres-paperless-pass.age".publicKeys = users ++ systems;
  "postgres-grafana-pass.age".publicKeys = users ++ systems;
  "postgres-nextcloud-pass.age".publicKeys = users ++ systems;
  "postgres-immich-pass.age".publicKeys = users ++ systems;
  "postgres-hass-pass.age".publicKeys = users ++ systems;
  "paperless-secret-key.age".publicKeys = users ++ systems;
  "paperless-admin-pass.age".publicKeys = users ++ systems;
  "radicale-htpasswd.age".publicKeys = users ++ systems;

  # Fase D.3 — Keycloak SSO
  "keycloak-db-pass.age".publicKeys = users ++ systems;
  "keycloak-admin-pass.age".publicKeys = users ++ systems;
  "keycloak-zfs-key.age".publicKeys = users ++ systems;       # raw 32-byte ZFS encryption key
  "keycloak-smtp-pass.age".publicKeys = users ++ systems;     # Google Workspace App Password

  # Fase D.4a — OIDC client secrets para servicios native-OIDC
  "oidc-client-vaultwarden.age".publicKeys = users ++ systems;
  "oidc-client-paperless.age".publicKeys = users ++ systems;
  "oidc-client-grafana.age".publicKeys = users ++ systems;
  "oidc-client-jellyfin.age".publicKeys = users ++ systems;
  "oidc-client-jellyseerr.age".publicKeys = users ++ systems;

  # Fase D.4b — OIDC client secrets para oauth2-proxy instances
  "oidc-client-oauth2proxy-sonarr.age".publicKeys = users ++ systems;
  "oidc-client-oauth2proxy-radarr.age".publicKeys = users ++ systems;
  "oidc-client-oauth2proxy-prowlarr.age".publicKeys = users ++ systems;
  "oidc-client-oauth2proxy-bazarr.age".publicKeys = users ++ systems;
  "oidc-client-oauth2proxy-deluge.age".publicKeys = users ++ systems;
  "oidc-client-oauth2proxy-homepage.age".publicKeys = users ++ systems;
  "oidc-client-oauth2proxy-kuma.age".publicKeys = users ++ systems;
  "oidc-client-oauth2proxy-prometheus.age".publicKeys = users ++ systems;

  # Fase D.4b — cookie-secret compartido por todas las instancias oauth2-proxy
  # (44-byte base64 random — usado para firmar/cifrar cookies de sesión).
  "oauth2-proxy-cookie-secret.age".publicKeys = users ++ systems;

  # Fase D.4b — break-glass localadmin passwords para servicios *arr cuando
  # SSO se rompa (autenticación interna queda como fallback).
  "sonarr-localadmin-pass.age".publicKeys = users ++ systems;
  "radarr-localadmin-pass.age".publicKeys = users ++ systems;
  "prowlarr-localadmin-pass.age".publicKeys = users ++ systems;
  "bazarr-localadmin-pass.age".publicKeys = users ++ systems;

  # R0 — Vaultwarden auto-sync helper credentials
  "bw-api-clientid.age".publicKeys = users ++ systems;
  "bw-api-clientsecret.age".publicKeys = users ++ systems;
  "bw-mauri-master.age".publicKeys = users ++ systems;
}
