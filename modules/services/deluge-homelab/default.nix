{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.deluge-homelab;
  secretsRoot = "${inputs.secrets}/secrets";
in
{
  options.services.deluge-homelab = {
    enable = lib.mkEnableOption ''
      Deluge BitTorrent client (Path A: no-VPN con encryption forced + bind tailscale0).

      Behavior config diseñado para minimizar visibilidad swarm en AR sin VPN:
      - encryption=forced both directions, prefer RC4
      - max_connections_global=100 (vs default 200)
      - listen ports fijos 6881-6889 (sin UPnP)
      - DHT/PEX/LSD enabled (públicos OK; per-torrent override desde *arr)
    '';

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 8112;
    };

    daemonPort = lib.mkOption {
      type = lib.types.port;
      default = 58846;
      description = "Deluged RPC port (loopback only, *arr lo usa).";
    };

    btListenPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 6881 6889 ];
      description = "Range [low high] para listening BT.";
    };

    downloadDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/downloads/complete";
    };

    incompleteDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/downloads/incomplete";
    };

    webUser = lib.mkOption {
      type = lib.types.str;
      default = "mauri";
      description = "Username del web UI (auth file user:pass:level).";
    };

    bindOnLan = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Si true, web UI bindea también en LAN (peligroso sin firewall extra).
        Default false → web UI accesible solo via Tailscale Serve / loopback.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Secret: web UI password (idem patrón otros servicios homelab).
    # Group=media porque services.deluge.group="media" → primary group del user.
    age.secrets.delugeWebPass = {
      file  = "${secretsRoot}/deluge-web-pass.age";
      owner = "deluge";
      group = "media";
      mode  = "0400";
    };

    # NixOS deluge module: declarative=true → genera core.conf desde cfg.config
    # y NUNCA lo sobreescribe via UI (UI puede cambiar cosas pero al restart vuelve).
    services.deluge = {
      enable = true;
      declarative = true;
      dataDir = "/var/lib/deluge";
      user = "deluge";
      group = "media";   # share with *arr/jellyfin para hardlinks

      # AuthFile en formato Deluge: <user>:<pass>:<level> por línea, level 10 = admin
      # Generado por oneshot prepare a partir del agenix secret (mismo patrón
      # paperless-db-env-prepare). NO usar configFile estático con literal pass.
      authFile = "/run/deluge/auth";

      config = {
        # Flow: incomplete/ → complete/ on finish. *arr poll-importa desde complete/.
        download_location = cfg.incompleteDir;
        move_completed = true;
        move_completed_path = cfg.downloadDir;
        torrentfiles_location = "/var/lib/deluge/torrents";
        plugins_location = "/var/lib/deluge/plugins";
        copy_torrent_file = true;
        del_copy_torrent_file = false;

        # Listen ports fijos (sin UPnP/NAT-PMP — privacy + no router auto-config)
        listen_ports = cfg.btListenPorts;
        random_port = false;
        upnp = false;
        natpmp = false;
        outgoing_ports = [ 0 0 ];

        # Encryption FORCED RC4 only — no plaintext fallback
        enc_in_policy = 2;             # 0=disabled, 1=enabled, 2=forced
        enc_out_policy = 2;
        enc_level = 1;                 # 0=plaintext, 1=rc4, 2=either
        prefer_rc4 = true;

        # Connection caps (Path A swarm visibility mitigation)
        max_connections_global = 100;
        max_connections_per_torrent = 30;
        max_upload_slots_global = 8;
        max_upload_slots_per_torrent = 4;
        max_upload_speed = -1.0;
        max_download_speed = -1.0;
        max_active_downloading = 5;
        max_active_seeding = 8;
        max_active_limit = 12;
        dont_count_slow_torrents = true;

        # Discovery (públicos OK; *arr override per-torrent para private trackers)
        dht = true;
        pex = true;
        lsd = true;
        utpex = true;

        # Seed-stop behavior público
        stop_seed_at_ratio = true;
        stop_seed_ratio = 1.5;
        share_ratio_limit = 1.5;
        seed_time_ratio_limit = 7.0;
        seed_time_limit = 180;          # minutos (3 hs)
        remove_seed_at_ratio = false;   # no borrar — *arr decide

        # daemon RPC (loopback only)
        daemon_port = cfg.daemonPort;
        allow_remote = false;

        # Privacidad
        new_release_check = false;
        send_info = false;
      };

      web = {
        enable = true;
        port = cfg.webPort;
      };
    };

    # Generate authFile from agenix secret. Deluge format: user:pass:level\n
    # Level 10 = admin (full access). Web UI usa este file para auth.
    systemd.services.deluge-auth-prepare = {
      description = "Render deluge authFile + web.conf password from agenix";
      after = [ "agenix.service" "deluge-storage-prepare.service" ];
      requires = [ "deluge-storage-prepare.service" ];
      before = [ "deluged.service" "delugeweb.service" ];
      wantedBy = [ "deluged.service" "delugeweb.service" ];
      path = with pkgs; [ coreutils openssl gawk ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        umask 077
        # Group del deluge user es "media" (services.deluge.group); no existe "deluge" group.
        install -d -m 0750 -o deluge -g media /run/deluge
        pass=$(cat ${config.age.secrets.delugeWebPass.path})

        # ── /run/deluge/auth: deluged daemon RPC auth (cfg.authFile apunta acá)
        install -m 0400 -o deluge -g media /dev/null /run/deluge/auth
        printf '%s:%s:10\n' "${cfg.webUser}" "$pass" > /run/deluge/auth
        chown deluge:media /run/deluge/auth
        chmod 0400 /run/deluge/auth

        # ── /var/lib/deluge/.config/deluge/auth: localclient handshake de delugeweb
        install -d -m 0750 -o deluge -g media \
          /var/lib/deluge/.config /var/lib/deluge/.config/deluge
        install -m 0600 -o deluge -g media /dev/null \
          /var/lib/deluge/.config/deluge/auth
        printf 'localclient:%s:10\n' "$pass" > /var/lib/deluge/.config/deluge/auth

        # ── /var/lib/deluge/.config/deluge/web.conf: web UI password (sha1+salt).
        # Sin esto, web UI usa default "deluge" → *arr no se puede conectar.
        # Marcador `.web-pwd-managed` evita re-renderizar (cada render genera salt
        # nuevo y obligaría restart). Si querés rotar password: rm el marker + restart.
        WEB_CONF=/var/lib/deluge/.config/deluge/web.conf
        MARKER=/var/lib/deluge/.config/deluge/.web-pwd-managed
        if [ ! -f "$MARKER" ]; then
          SALT=$(openssl rand -hex 32)
          PWD_SHA1=$(printf '%s%s' "$SALT" "$pass" | openssl sha1 | awk '{print $2}')
          install -m 0600 -o deluge -g media /dev/null "$WEB_CONF"
          # Format Deluge: dos JSON objects (file/format header + content).
          cat > "$WEB_CONF" <<JSON
{
    "file": 2,
    "format": 1
}{
    "pwd_sha1": "$PWD_SHA1",
    "pwd_salt": "$SALT",
    "session_timeout": 3600,
    "default_daemon": "",
    "show_session_speed": false,
    "show_sidebar": true,
    "sidebar_show_zero": false,
    "sidebar_show_trackers": true,
    "sidebar_multiple_filters": true,
    "language": "",
    "theme": "gray",
    "first_login": false,
    "https": false,
    "interface": "0.0.0.0",
    "port": 8112,
    "base": "/"
}
JSON
          chown deluge:media "$WEB_CONF"
          chmod 0600 "$WEB_CONF"
          install -m 0600 -o deluge -g media /dev/null "$MARKER"
          echo "[deluge-auth-prepare] web.conf renderizado con password de agenix"
          # Forzar restart de delugeweb si ya estaba running con default password.
          # --no-block evita deadlock si delugeweb está pidiendo nuestro propio start.
          /run/current-system/sw/bin/systemctl --no-block try-restart delugeweb || true
        fi
      '';
    };

    # ── Firewall: BT listen ports + web UI bind ──────────────────────────────
    # BT inbound: abierto en LAN+tailscale (necesario para swarm; outbound-only
    # solo se conecta a peers que iniciaron, swarm chico).
    networking.firewall.allowedTCPPortRanges = [
      { from = builtins.elemAt cfg.btListenPorts 0;
        to   = builtins.elemAt cfg.btListenPorts 1; }
    ];
    networking.firewall.allowedUDPPortRanges = [
      { from = builtins.elemAt cfg.btListenPorts 0;
        to   = builtins.elemAt cfg.btListenPorts 1; }
    ];

    # Web UI: SOLO tailscale (trustedInterfaces) y loopback. NO se abre puerto
    # en allowedTCPPorts — TS Serve termina TLS en :8112 y proxy-passa a loopback.
    # Si cfg.bindOnLan=true, abrir en LAN; default false.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts =
      [ cfg.webPort ];

    # ── Storage ownership post-mount ─────────────────────────────────────────
    systemd.services.deluge-storage-prepare = {
      description = "Fix /srv/downloads ownership post-ZFS-mount";
      after = [ "srv-downloads.mount" "var-lib-deluge.mount" ];
      requires = [ "srv-downloads.mount" "var-lib-deluge.mount" ];
      before = [ "deluged.service" ];
      wantedBy = [ "deluged.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # /var/lib/deluge: state DB, propio
        ${pkgs.coreutils}/bin/chown deluge:media /var/lib/deluge
        ${pkgs.coreutils}/bin/chmod 0750 /var/lib/deluge

        # NixOS deluge pre-start hace `cp ... /var/lib/deluge/.config/deluge/core.conf`,
        # asume el subdir existe. Lo creamos.
        ${pkgs.coreutils}/bin/install -d -m 0750 -o deluge -g media \
          /var/lib/deluge/.config \
          /var/lib/deluge/.config/deluge

        # /srv/downloads: setgid 2775 para que *arr (group=media) pueda hardlink
        # desde complete/ a /srv/storage/media/...
        ${pkgs.coreutils}/bin/install -d -m 2775 -o deluge -g media \
          /srv/downloads \
          ${cfg.incompleteDir} \
          ${cfg.downloadDir}
      '';
    };
  };
}
