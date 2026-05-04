{ config, lib, pkgs, ... }:
{
  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "server";
    # Sin authKeyFile: el bootstrap dinamico (tailscaled-autoconnect-oauth abajo)
    # genera un authkey one-shot via OAuth en cada arranque que lo necesite.
    # NixOS upstream no crea su tailscaled-autoconnect.service cuando authKeyFile
    # no esta seteado, asi que no hay conflicto de units.
  };

  # Desactiva reverse-path filter en interfaz Tailscale (necesario para exit-node).
  networking.firewall.checkReversePath = "loose";

  # Bootstrap dinamico: en lugar de un authkey persistente en agenix (que expira
  # cada 90 dias), usamos un OAuth client (que vive ~indefinidamente) para
  # generar authkeys one-shot al boot solo si el nodo no esta autenticado.
  # En operacion normal (BackendState=Running) el script es noop, cero costo.
  systemd.services.tailscaled-autoconnect-oauth = {
    description = "Tailscale autoconnect via OAuth (generates one-shot authkey)";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    path = [ pkgs.tailscale pkgs.curl pkgs.jq pkgs.coreutils ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      LoadCredential = [
        "client-id:${config.age.secrets.tailscaleOauthClientId.path}"
        "client-secret:${config.age.secrets.tailscaleOauthClientSecret.path}"
      ];
    };

    script = ''
      set -euo pipefail

      # Idempotente: si el nodo ya esta conectado al tailnet con su node key
      # persistente, no hace falta authkey nuevo.
      STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState' || echo "Unknown")
      if [ "$STATUS" = "Running" ]; then
        echo "[ts-oauth] BackendState=Running -- nothing to do"
        exit 0
      fi
      echo "[ts-oauth] BackendState=$STATUS -- bootstrapping with OAuth"

      CLIENT_ID=$(cat "$CREDENTIALS_DIRECTORY/client-id")
      CLIENT_SECRET=$(cat "$CREDENTIALS_DIRECTORY/client-secret")

      # 1. OAuth2 client_credentials grant (~1h validity).
      ACCESS_TOKEN=$(curl -fsS \
        -u "$CLIENT_ID:$CLIENT_SECRET" \
        -d 'grant_type=client_credentials' \
        https://api.tailscale.com/api/v2/oauth/token \
        | jq -r '.access_token')
      if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
        echo "[ts-oauth] failed to obtain OAuth access_token" >&2
        exit 1
      fi

      # 2. Generate one-shot authkey: 10min expiry, NOT reusable, preauthorized,
      #    attributed to tag:server (definido en la ACL del tailnet).
      AUTH_KEY=$(curl -fsS -X POST \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["tag:server"]}}},"expirySeconds":600,"description":"home-server bootstrap"}' \
        https://api.tailscale.com/api/v2/tailnet/-/keys \
        | jq -r '.key')
      if [ -z "$AUTH_KEY" ] || [ "$AUTH_KEY" = "null" ]; then
        echo "[ts-oauth] failed to generate authkey" >&2
        exit 1
      fi

      echo "[ts-oauth] tailscale up with fresh one-shot authkey"
      tailscale up --auth-key="$AUTH_KEY" \
        --hostname=home-server \
        --advertise-exit-node \
        --ssh \
        --reset

      echo "[ts-oauth] bootstrap complete"
    '';
  };
}
