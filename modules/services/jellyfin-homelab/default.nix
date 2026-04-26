{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.jellyfin-homelab;
  secretsRoot = "${inputs.secrets}/secrets";
in
{
  options.services.jellyfin-homelab = {
    enable = lib.mkEnableOption ''
      Jellyfin streaming server con HW accel Intel QuickSync (Haswell iGPU).
      Loopback only — exposure via Tailscale Serve en home-server.
    '';

    port = lib.mkOption {
      type = lib.types.port;
      default = 8096;
    };

    mediaRoot = lib.mkOption {
      type = lib.types.path;
      default = "/srv/storage/media";
      description = ''
        Raíz de las libraries (subdirs movies/, tv/, music/). Mismo pool que
        /srv/downloads para hardlinks atómicos *arr → jellyfin (no copy).
      '';
    };

    configDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/jellyfin";
      description = "Library DB + config + plugins. SSD.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/jellyfin";
      description = "Transcode cache + thumbnails. SSD; volátil OK.";
    };

    hwAccel = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Habilitar Intel QuickSync en /dev/dri/renderD128. Reduce CPU
        de transcode 4K H264→H264 de ~80% a ~5%. Falla silenciosa a CPU
        si el driver no carga (Jellyfin auto-detecta).
      '';
    };

    autoBootstrap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Si está habilitado, corre un oneshot que automatiza el wizard inicial:
        crea admin user + 3 libraries (movies, tv, music) via API. Idempotente:
        si el wizard ya está completado (POST /Startup/* devuelve 401), skip.
      '';
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "mauri";
      description = "Nombre del admin user creado por el bootstrap.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Group `media` compartido entre todos los servicios E.2 que tocan files
    # de media/downloads (jellyfin reads, *arr writes hardlinks, deluge writes).
    users.groups.media = { };

    # Jellyfin nativo. user/group asignados por el módulo NixOS.
    services.jellyfin = {
      enable = true;
      group = "media";          # NixOS module hace addon a jellyfin's primary group
      dataDir = cfg.configDir;
      cacheDir = cfg.cacheDir;
      openFirewall = false;     # loopback only — TS Serve hace ingress
    };

    # Jellyfin user en grupos render/video para acceso a /dev/dri/* (QSV).
    users.users.jellyfin.extraGroups = lib.mkIf cfg.hwAccel [ "render" "video" ];

    # Force loopback bind (módulo no expone listenAddress; usar settings file).
    # Jellyfin honra `JELLYFIN_BIND_ADDR` env var → http_listen_addr en el HTTP server.
    systemd.services.jellyfin.environment = {
      JELLYFIN_BIND_ADDR = "127.0.0.1";
    };

    # ── HW acceleration (Intel QSV) ──────────────────────────────────────────
    # OpenGL stack + drivers VAAPI Intel para Haswell (gen 4 → QSV vía VA-API).
    # graphics.enable habilita 32-bit + extra packages disponible para el container.
    hardware.graphics = lib.mkIf cfg.hwAccel {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        intel-media-driver       # iHD (Broadwell+)
        vaapiIntel               # i965 (Ivy/Haswell era — backup driver)
        intel-vaapi-driver       # alias del anterior en algunos releases
        libvdpau-va-gl
      ];
    };

    # ── Storage ownership post-mount ─────────────────────────────────────────
    # Datasets ZFS recién creados son root:root 0755. Lección E.3:
    # tmpfiles corre at sysinit ANTES del mount → sus rules se aplican al dir
    # subyacente, hidden por el mount. Solución: oneshot per-dir DESPUÉS del mount.
    systemd.services.jellyfin-storage-prepare = {
      description = "Fix media+config dirs ownership post-ZFS-mount";
      after = [
        "var-lib-jellyfin.mount"
        "var-cache-jellyfin.mount"
        "srv-storage-media-movies.mount"
        "srv-storage-media-tv.mount"
        "srv-storage-media-music.mount"
      ];
      requires = [
        "var-lib-jellyfin.mount"
        "var-cache-jellyfin.mount"
        "srv-storage-media-movies.mount"
        "srv-storage-media-tv.mount"
        "srv-storage-media-music.mount"
      ];
      before = [ "jellyfin.service" ];
      wantedBy = [ "jellyfin.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # config + cache dirs son del user jellyfin
        ${pkgs.coreutils}/bin/chown jellyfin:media ${cfg.configDir} ${cfg.cacheDir}
        ${pkgs.coreutils}/bin/chmod 0750         ${cfg.configDir} ${cfg.cacheDir}

        # /srv/storage/media + subdirs: setgid para que hardlinks de *arr preserven
        # el group=media. owner jellyfin (jellyfin lee, *arr escriben via group).
        ${pkgs.coreutils}/bin/install -d -m 2775 -o jellyfin -g media \
          ${cfg.mediaRoot} \
          ${cfg.mediaRoot}/movies \
          ${cfg.mediaRoot}/tv \
          ${cfg.mediaRoot}/music
      '';
    };

    # ── Auto-bootstrap (admin user + libraries) ──────────────────────────────
    age.secrets.jellyfinAdminPass = lib.mkIf cfg.autoBootstrap {
      file  = "${secretsRoot}/jellyfin-admin-pass.age";
      owner = "root";
      group = "root";
      mode  = "0400";
    };

    systemd.services.jellyfin-bootstrap = lib.mkIf cfg.autoBootstrap {
      description = "Idempotent first-boot config: admin user + 3 libraries";
      after = [ "jellyfin.service" "network.target" ];
      requires = [ "jellyfin.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ curl jq coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Re-correr en cada deploy es OK porque el script es idempotente
        # (POST /Startup/* retorna 401 después del wizard).
        Restart = "on-failure";
        RestartSec = "30s";
        LoadCredential = "admin-pass:${config.age.secrets.jellyfinAdminPass.path}";
      };
      script = ''
        set -euo pipefail
        JF=http://127.0.0.1:${toString cfg.port}
        ADMIN_USER=${cfg.adminUser}
        ADMIN_PASS=$(cat "$CREDENTIALS_DIRECTORY/admin-pass")

        # Esperar hasta 120s a que Jellyfin esté listo.
        for i in $(seq 1 120); do
          if curl -sf "$JF/System/Info/Public" >/dev/null; then break; fi
          sleep 1
        done

        # Si /Startup/Configuration retorna 401, el wizard ya fue completado.
        SETUP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
          -X POST "$JF/Startup/Configuration" \
          -H 'Content-Type: application/json' \
          -d '{"UICulture":"es-AR","MetadataCountryCode":"AR","PreferredMetadataLanguage":"es"}')

        if [ "$SETUP_CODE" = "401" ] || [ "$SETUP_CODE" = "403" ]; then
          echo "[bootstrap] Jellyfin wizard already completed (HTTP $SETUP_CODE) — skipping"
          exit 0
        fi
        if [ "$SETUP_CODE" != "204" ] && [ "$SETUP_CODE" != "200" ]; then
          echo "[bootstrap] unexpected response $SETUP_CODE on /Startup/Configuration" >&2
          exit 1
        fi

        # Crear admin user
        curl -sf -X POST "$JF/Startup/User" \
          -H 'Content-Type: application/json' \
          -d "{\"Name\":\"$ADMIN_USER\",\"Password\":\"$ADMIN_PASS\"}"

        # Marcar wizard completo
        curl -sf -X POST "$JF/Startup/Complete"

        echo "[bootstrap] admin user $ADMIN_USER creado"

        # Obtener token de auth via login (para crear libraries)
        TOKEN=$(curl -sf -X POST "$JF/Users/AuthenticateByName" \
          -H 'Content-Type: application/json' \
          -H 'Authorization: MediaBrowser Client="bootstrap", Device="nixos", DeviceId="nixos-home-server", Version="1.0"' \
          -d "{\"Username\":\"$ADMIN_USER\",\"Pw\":\"$ADMIN_PASS\"}" \
          | jq -r .AccessToken)

        if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
          echo "[bootstrap] no se pudo obtener token" >&2
          exit 1
        fi

        # Listar VirtualFolders existentes para idempotencia
        EXISTING=$(curl -sf "$JF/Library/VirtualFolders" \
          -H "X-Emby-Token: $TOKEN" | jq -r '.[].Name' || echo "")

        create_lib() {
          local name="$1"
          local type="$2"
          local path="$3"
          if echo "$EXISTING" | grep -q "^$name\$"; then
            echo "[bootstrap] library $name ya existe — skip"
            return
          fi
          # Path-encode espacios en el nombre
          local enc_name=$(echo "$name" | jq -sRr @uri)
          curl -sf -X POST "$JF/Library/VirtualFolders?name=$enc_name&collectionType=$type&refreshLibrary=false" \
            -H "X-Emby-Token: $TOKEN" \
            -H 'Content-Type: application/json' \
            -d "{\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"$path\"}]}}"
          echo "[bootstrap] library $name creada → $path"
        }

        create_lib "Movies"   "movies"   "${cfg.mediaRoot}/movies"
        create_lib "TV Shows" "tvshows"  "${cfg.mediaRoot}/tv"
        create_lib "Music"    "music"    "${cfg.mediaRoot}/music"

        echo "[bootstrap] OK"
      '';
    };
  };
}
