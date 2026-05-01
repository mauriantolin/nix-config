{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.fail2ban-cloudflare-homelab;
  secretsRoot = "${inputs.secrets}/secrets";

  cloudflareActionScript = pkgs.writeShellScript "cloudflare-action.sh" ''
    set -euo pipefail
    ACTION="$1"
    IP="$2"
    JAIL="$3"
    TOKEN_FILE="${cfg.apiTokenFile}"
    ZONE="${cfg.cfZone}"
    CACHE_DIR="/run/fail2ban"
    ZONE_ID_FILE="$CACHE_DIR/cf-zone-id-$ZONE"

    mkdir -p "$CACHE_DIR"

    if [ ! -s "$ZONE_ID_FILE" ]; then
      ${pkgs.curl}/bin/curl -sS \
        -H "Authorization: Bearer $(cat $TOKEN_FILE)" \
        "https://api.cloudflare.com/client/v4/zones?name=$ZONE" \
        | ${pkgs.jq}/bin/jq -r '.result[0].id' > "$ZONE_ID_FILE"
    fi
    ZONE_ID="$(cat $ZONE_ID_FILE)"

    case "$ACTION" in
      ban)
        ${pkgs.curl}/bin/curl -sS -X POST \
          -H "Authorization: Bearer $(cat $TOKEN_FILE)" \
          -H "Content-Type: application/json" \
          --data "{\"mode\":\"${cfg.blockMode}\",\"configuration\":{\"target\":\"ip\",\"value\":\"$IP\"},\"notes\":\"fail2ban $JAIL $(date -Iseconds)\"}" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/access_rules/rules" \
          > /dev/null
        ;;
      unban)
        RULE_ID=$(${pkgs.curl}/bin/curl -sS \
          -H "Authorization: Bearer $(cat $TOKEN_FILE)" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/access_rules/rules?configuration.value=$IP" \
          | ${pkgs.jq}/bin/jq -r '.result[0].id // empty')
        if [ -n "$RULE_ID" ]; then
          ${pkgs.curl}/bin/curl -sS -X DELETE \
            -H "Authorization: Bearer $(cat $TOKEN_FILE)" \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/access_rules/rules/$RULE_ID" \
            > /dev/null
        fi
        ;;
      *) echo "unknown action: $ACTION" >&2; exit 1;;
    esac
  '';

  actionConf = ''
    [Definition]
    actionstart =
    actionstop  =
    actioncheck =
    actionban   = ${cloudflareActionScript} ban <ip> <name>
    actionunban = ${cloudflareActionScript} unban <ip> <name>
  '';

  # Filter para Vaultwarden. `journalmatch` se setea en el jail, no acá.
  # <HOST> es el macro de fail2ban que captura la IP (IPv4 o IPv6).
  vaultwardenFilterConf = ''
    [Definition]
    failregex = ^.*Username or password is incorrect\. Try again\. IP: <HOST>\. Username:.*$
                ^.*Invalid admin token\. IP: <HOST>\.$
    ignoreregex =
  '';
in
{
  options.services.fail2ban-cloudflare-homelab = {
    enable       = lib.mkEnableOption "fail2ban action que pushea IPs baneadas a CF firewall";
    apiTokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/agenix/cloudflareApiToken";
      description = "Path al secret con el API token de CF (scope Zone:Firewall Edit + Zone:Read).";
    };
    cfZone = lib.mkOption {
      type = lib.types.str;
      default = "mauricioantolin.com";
    };
    blockMode = lib.mkOption {
      type = lib.types.enum [ "block" "challenge" "js_challenge" "managed_challenge" ];
      default = "block";
    };
    enableVaultwardenJail = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Activa el jail `vaultwarden` con filter + action CF (usa journald backend).";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets.cloudflareApiToken = {
      file = "${secretsRoot}/cloudflare-api-token.age";
      # fail2ban runs as root on NixOS (no dedicated fail2ban user exists).
      # Root-owned 0400 is correct; the action script runs under fail2ban's root context.
      mode = "0400";
    };

    environment.etc."fail2ban/action.d/cloudflare-homelab.conf".text = actionConf;
    environment.etc."fail2ban/filter.d/vaultwarden.conf".text = vaultwardenFilterConf;

    services.fail2ban = lib.mkIf cfg.enableVaultwardenJail {
      # backend=systemd lee de journald; journalmatch restringe a la unit de vaultwarden.
      # port 80,443,8222 es informativo (CF edge block no usa puerto local).
      jails.vaultwarden = ''
        enabled  = true
        filter   = vaultwarden
        backend  = systemd
        journalmatch = _SYSTEMD_UNIT=vaultwarden.service
        port     = 80,443,8222
        maxretry = 5
        findtime = 10m
        bantime  = 4h
        action   = %(action_)s
                   cloudflare-homelab
      '';
    };
  };
}
