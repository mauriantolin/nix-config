{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.fail2ban-jails-homelab;
  secretsRoot = "${inputs.secrets}/secrets";

  hasCloudflareJail = lib.any (j: j.backend == "cloudflare") (lib.attrValues cfg.jails);

  # === Cloudflare-edge action (heredada de Fase B) ===
  cloudflareActionScript = pkgs.writeShellScript "cf-edge-ban.sh" ''
    set -euo pipefail
    ACTION="$1"
    IP="$2"
    JAIL="$3"
    TOKEN_FILE="${cfg.cfApiTokenFile}"
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

  cfActionConf = ''
    [Definition]
    actionstart =
    actionstop  =
    actioncheck =
    actionban   = ${cloudflareActionScript} ban <ip> <name>
    actionunban = ${cloudflareActionScript} unban <ip> <name>
  '';

  # === Nftables-local action (NUEVO en D.1) ===
  # Crea/destruye la table inet fail2ban-homelab y un set con timeout.
  # priority -10 para que el drop sea ANTES del firewall principal de NixOS (priority 0).
  # ipv4-only banlist; samba's IPv6 inbound is firewall-dropped on the LAN iface
  # (see modules/services/samba/default.nix), so a v6 ban path is not exercised.
  # Extend to a second set type ipv6_addr if a future jail needs v6.
  nftActionConf = ''
    [Definition]
    actionstart = ${pkgs.nftables}/bin/nft delete table inet fail2ban-homelab 2>/dev/null || true
                  ${pkgs.nftables}/bin/nft add table inet fail2ban-homelab
                  ${pkgs.nftables}/bin/nft 'add set inet fail2ban-homelab banlist { type ipv4_addr ; flags interval, timeout ; }'
                  ${pkgs.nftables}/bin/nft 'add chain inet fail2ban-homelab input { type filter hook input priority -10 ; }'
                  ${pkgs.nftables}/bin/nft 'add rule inet fail2ban-homelab input ip saddr @banlist drop'
    actionstop  = ${pkgs.nftables}/bin/nft delete table inet fail2ban-homelab
    actioncheck =
    actionban   = ${pkgs.nftables}/bin/nft 'add element inet fail2ban-homelab banlist { <ip> timeout <bantime>s }'
    actionunban = ${pkgs.nftables}/bin/nft 'delete element inet fail2ban-homelab banlist { <ip> }' || true
  '';

  # === Per-jail filter file generator ===
  # Continuation lines of multi-line failregex must start with whitespace so
  # fail2ban's INI parser keeps them as part of the failregex value (otherwise
  # only the first line is loaded — silent regression).
  indentContinuations = s:
    lib.replaceStrings [ "\n" ] [ "\n            " ] (lib.removeSuffix "\n" s);

  mkFilterFile = name: jail: ''
    [Definition]
    failregex = ${indentContinuations jail.failregex}
    ignoreregex =
  '';

  # === Per-jail journal jail config ===
  mkJailConfig = name: jail: ''
    enabled  = true
    filter   = ${name}
    backend  = systemd
    journalmatch = _SYSTEMD_UNIT=${jail.service}.service
    maxretry = ${toString jail.maxRetry}
    findtime = ${jail.findTime}
    bantime  = ${jail.banTime}
    ${lib.optionalString (jail.ignoreIp != []) "ignoreip = ${lib.concatStringsSep " " jail.ignoreIp}"}
    action   = ${if jail.backend == "cloudflare" then "%(action_)s\n               cf-edge" else "nft-local"}
  '';
in
{
  options.services.fail2ban-jails-homelab = {
    enable = lib.mkEnableOption "fail2ban con jails attrset multi-backend (CF edge / nftables local)";

    cfZone = lib.mkOption {
      type = lib.types.str;
      default = "mauricioantolin.com";
      description = "DNS zone para action cf-edge.";
    };

    cfApiTokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/agenix/cloudflareApiToken";
      description = "Path al secret con CF API token (Zone:Firewall:Edit + Zone:Read).";
    };

    blockMode = lib.mkOption {
      type = lib.types.enum [ "block" "challenge" "js_challenge" "managed_challenge" ];
      default = "block";
      description = "Action mode pasado a CF firewall/access_rules.";
    };

    jails = lib.mkOption {
      default = { };
      description = "Per-jail config. Cada entry genera filter + jail.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          service = lib.mkOption {
            type = lib.types.str;
            description = "systemd unit name (sin .service) que loggea los failures.";
            example = "vaultwarden";
          };
          backend = lib.mkOption {
            type = lib.types.enum [ "cloudflare" "nftables" ];
            description = "Destino del ban: cloudflare (edge) o nftables (local).";
          };
          failregex = lib.mkOption {
            type = lib.types.str;
            description = "Patrón fail2ban (puede ser multi-línea).";
          };
          ignoreIp = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "127.0.0.1/8" "100.64.0.0/10" ];
          };
          maxRetry = lib.mkOption { type = lib.types.int; default = 5; };
          findTime = lib.mkOption { type = lib.types.str; default = "10m"; };
          banTime = lib.mkOption { type = lib.types.str; default = "1h"; };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Assertions
    {
      assertions = [
        {
          assertion = !hasCloudflareJail || cfg.cfApiTokenFile != "";
          message = "fail2ban-jails-homelab: hay jail con backend=cloudflare pero cfApiTokenFile vacío.";
        }
      ];
    }

    # Decrypt CF token solo si hay jail con backend=cloudflare
    (lib.mkIf hasCloudflareJail {
      age.secrets.cloudflareApiToken = {
        file = "${secretsRoot}/cloudflare-api-token.age";
        mode = "0400";
      };
    })

    # Action.d files (siempre se generan ambos; solo se usan los referidos por jails)
    {
      environment.etc."fail2ban/action.d/cf-edge.conf".text = cfActionConf;
      environment.etc."fail2ban/action.d/nft-local.conf".text = nftActionConf;
    }

    # Filter.d files per jail
    {
      environment.etc = lib.mapAttrs'
        (name: jail:
          lib.nameValuePair "fail2ban/filter.d/${name}.conf" {
            text = mkFilterFile name jail;
          }
        )
        cfg.jails;
    }

    # Jails config
    {
      services.fail2ban = {
        enable = true;
        extraPackages = [ pkgs.curl pkgs.jq pkgs.nftables ];
        jails = lib.mapAttrs (name: jail: mkJailConfig name jail) cfg.jails;
      };
    }
  ]);
}
