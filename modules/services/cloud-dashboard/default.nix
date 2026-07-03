{ config, lib, pkgs, ... }:
let
  cfg = config.services.cloud-dashboard;

  # Exporter: corre el aws CLI (ya autenticado vía ~/.aws del user) y escribe un
  # JSON plano que Homepage consume por customapi. NO expone credenciales: solo
  # el resultado (montos + estado). Cost Explorer cobra ~USD 0.01 por request →
  # cadencia larga (default 6h) a propósito; CloudFront list es gratis.
  exporter = pkgs.writeShellScriptBin "aws-dashboard-export" ''
    export PATH=${lib.makeBinPath [ pkgs.awscli2 pkgs.jq pkgs.coreutils ]}:$PATH
    set -euo pipefail
    out="''${1:-${cfg.stateDir}/aws.json}"
    start="$(date +%Y-%m-01)"
    end="$(date -d "$start +1 month" +%Y-%m-01)"

    mtd() { # $1 = profile → monto MTD (número), 0 si falla
      aws ce get-cost-and-usage --profile "$1" \
        --time-period Start="$start",End="$end" --granularity MONTHLY \
        --metrics UnblendedCost --output json 2>/dev/null \
        | jq -r '((.ResultsByTime[0].Total.UnblendedCost.Amount // "0") | tonumber)' 2>/dev/null \
        || echo 0
    }

    # Foco en la cuenta AWS personal (413238766843); factory-prod (org propia)
    # como secundaria. La sandbox ATOS queda fuera a propósito.
    personal="$(mtd personal)"; personal="''${personal:-0}"
    factory="$(mtd factory-prod)"; factory="''${factory:-0}"

    cf="$(aws cloudfront list-distributions --profile personal --output json 2>/dev/null || echo '{}')"
    site="$(echo "$cf" | jq -c '
      (.DistributionList.Items // []) as $i
      | ($i | map(select((.Aliases.Items // []) | index("mauricioantolin.com"))) | .[0]) as $main
      | {
          status:        ($main.Status // "unknown"),
          enabled:       ($main.Enabled // false),
          aliases:       (($main.Aliases.Items // []) | join(", ")),
          distributions: ($i | length),
          all_deployed:  (($i | length) > 0 and ($i | all(.[]; .Status == "Deployed")))
        }' 2>/dev/null || echo '{"status":"error","distributions":0}')"

    updated="$(date '+%Y-%m-%d %H:%M')"

    jq -n \
      --argjson personal "$personal" --argjson factory "$factory" \
      --argjson site "$site" --arg updated "$updated" '
      {
        updated: $updated,
        aws: {
          personal: { account: "413238766843", mtd: (($personal * 100) | round / 100) },
          factory:  { account: "035268396878", mtd: (($factory * 100) | round / 100) }
        },
        site: $site
      }' > "$out.tmp"
    mv -f "$out.tmp" "$out"
  '';
in
{
  options.services.cloud-dashboard = {
    enable = lib.mkEnableOption "Cloud (AWS) exporter para Homepage (customapi vía loopback)";
    user = lib.mkOption {
      type = lib.types.str;
      default = "mauri";
      description = "Usuario cuyas credenciales ~/.aws usa el exporter.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8765;
      description = "Puerto loopback donde se sirve el JSON para customapi.";
    };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/cloud-dashboard";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "6h";
      description = "Cadencia del refresh (Cost Explorer cobra por request → no bajar mucho).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0755 ${cfg.user} users - -"
    ];

    systemd.services.aws-dashboard-export = {
      description = "Export AWS cost/health JSON for Homepage";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Environment = [ "HOME=/home/${cfg.user}" ];
        ExecStart = "${exporter}/bin/aws-dashboard-export ${cfg.stateDir}/aws.json";
      };
    };

    systemd.timers.aws-dashboard-export = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = cfg.interval;
        Persistent = true;
      };
    };

    # Sirve el JSON en loopback; Homepage (--network=host) lo alcanza por
    # 127.0.0.1. Bind explícito a loopback → no reachable desde tailnet/LAN.
    systemd.services.cloud-dashboard-serve = {
      description = "Serve cloud-dashboard JSON on loopback for Homepage customapi";
      after = [ "aws-dashboard-export.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString cfg.port} --bind 127.0.0.1 --directory ${cfg.stateDir}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
