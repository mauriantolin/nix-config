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
  # ── Secretos activos (post-depuración tailscale-only, 2026-06-28) ──────────────
  # Todo lo de servicios eliminados (keycloak/oauth2-proxy/*arr/paperless/grafana/
  # radicale/nextcloud/hass/cloudflared + hello-secret demo) fue podado.

  # Usuario Linux mauri (login + sudo)
  "mauri-hashed-password.age".publicKeys = users ++ systems;

  # Vaultwarden (admin token) + Samba (mauri)
  "vaultwarden-admin-token.age".publicKeys = users ++ systems;
  "smb-mauri-password.age".publicKeys = users ++ systems;

  # Tailscale OAuth bootstrap (genera authkeys one-shot al boot)
  "tailscale-oauth-client-id.age".publicKeys = users ++ systems;
  "tailscale-oauth-client-secret.age".publicKeys = users ++ systems;

  # Vaultwarden auto-sync helper (master + API creds)
  "bw-api-clientid.age".publicKeys = users ++ systems;
  "bw-api-clientsecret.age".publicKeys = users ++ systems;
  "bw-mauri-master.age".publicKeys = users ++ systems;

  # GitHub PATs (3 cuentas) para los MCP de los repos en el box de agentes
  "github-pat-mauriantolin.age".publicKeys = users ++ systems;
  "github-pat-casallab.age".publicKeys = users ++ systems;
  "github-pat-tpcai.age".publicKeys = users ++ systems;
}
