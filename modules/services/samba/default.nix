{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.samba-homelab;
  secretsRoot = "${inputs.secrets}/secrets";
in
{
  options.services.samba-homelab = {
    enable = lib.mkEnableOption "Samba share homelab (single user `mauri`, LAN+Tailnet, SMB3)";
    user = lib.mkOption {
      type = lib.types.str;
      default = "mauri";
      description = "Unix user (must already exist) that owns the share + is the Samba user.";
    };
    sharePath = lib.mkOption {
      type = lib.types.path;
      default = "/srv/storage/shares";
      description = "Directorio raíz del share — respaldado por tank/storage/shares.";
    };
    lanInterface = lib.mkOption {
      type = lib.types.str;
      default = "enp2s0";
      description = "Nombre real de la interfaz LAN (verificado con `ip -br link`).";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets.smbMauriPassword = {
      file  = "${secretsRoot}/smb-mauri-password.age";
      # Leído por systemd-samba-user-setup como root al arranque.
      owner = "root";
      group = "root";
      mode  = "0400";
    };

    services.samba = {
      enable = true;
      openFirewall = false;   # firewall lo manejamos nosotros per-iface
      settings = {
        global = {
          "workgroup"            = "WORKGROUP";
          "server string"        = "home-server";
          "server role"          = "standalone server";
          "security"             = "user";
          "min protocol"         = "SMB3";
          "map to guest"         = "Never";
          "dns proxy"            = "no";
          "log file"             = "/var/log/samba/log.%m";
          "max log size"         = "1000";
          "logging"              = "file";
          # NO usamos `bind interfaces only` porque Samba rechaza interfaces
          # non-broadcast (tailscale0 es point-to-point /32) — log dice
          # "not adding non-broadcast interface". En su lugar: smbd escucha
          # en 0.0.0.0:445 y el firewall NixOS restringe :445 a enp2s0 + tailscale0.
          # Control de acceso a nivel Samba vía `hosts allow`.
          "hosts allow"          = "127. 192.168.0. 100.64.0.0/10";
          "hosts deny"           = "0.0.0.0/0";
        };
        ${cfg.user} = {
          "path"             = cfg.sharePath;
          "comment"          = "${cfg.user} personal share";
          "browseable"       = "yes";
          "read only"        = "no";
          "guest ok"         = "no";
          "create mask"      = "0644";
          "directory mask"   = "0755";
          "valid users"      = cfg.user;
        };
      };
    };

    # Ownership del share + logdir
    systemd.tmpfiles.rules = [
      "d ${cfg.sharePath} 0755 ${cfg.user} users -"
      "d /var/log/samba   0755 root       root  -"
    ];

    # Crea o actualiza el usuario SMB usando el secret. Idempotente: si el user
    # existe, corre -s (update password); si no, -a -s (create with password).
    systemd.services.samba-user-setup = {
      description = "Ensure SMB user `${cfg.user}` exists with password from agenix";
      after    = [ "agenix.service" "local-fs.target" ];
      wantedBy = [ "samba-smbd.service" ];
      before   = [ "samba-smbd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        PASS=$(cat /run/agenix/smbMauriPassword)
        if ${pkgs.samba}/bin/pdbedit -L 2>/dev/null | grep -q '^${cfg.user}:'; then
          (echo "$PASS"; echo "$PASS") | ${pkgs.samba}/bin/smbpasswd -s ${cfg.user}
        else
          (echo "$PASS"; echo "$PASS") | ${pkgs.samba}/bin/smbpasswd -s -a ${cfg.user}
        fi
      '';
    };

    # Firewall: 445/tcp en LAN. `lo` y `tailscale0` ya están en trustedInterfaces (Fase A),
    # no hace falta abrir puerto ahí.
    networking.firewall.interfaces.${cfg.lanInterface}.allowedTCPPorts = [ 445 ];

    # Defensa en profundidad: dropeo explícito de IPv6 inbound a :445 en enp2s0.
    # La interfaz tiene IPv6 público (2800:...) asignado por el ISP; si el router
    # deja pasar IPv6 inbound desde internet, cualquiera podría tocar smbd.
    # IPv4 en enp2s0 queda permitido vía la regla de arriba (port-forward 445 no existe
    # y hay NAT en el router). `-I` inserta al tope para ganarle al accept.
    networking.firewall.extraCommands = ''
      ip6tables -I nixos-fw -i ${cfg.lanInterface} -p tcp --dport 445 -j nixos-fw-refuse
    '';
    networking.firewall.extraStopCommands = ''
      ip6tables -D nixos-fw -i ${cfg.lanInterface} -p tcp --dport 445 -j nixos-fw-refuse 2>/dev/null || true
    '';
  };
}
