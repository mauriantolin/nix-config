{ lib, ... }:
{
  disko.devices = {
    disk = {
      # SSD 223 GB — contiene ESP, swap plano, y vdev de rpool
      ssd = {
        type = "disk";
        device = "/dev/disk/by-id/ata-HS-SSD-C100_240G_30070503557";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = {
              size = "8G";
              content = {
                type = "swap";
                discardPolicy = "both";
                resumeDevice = true;
              };
            };
            rpool = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };
          };
        };
      };

      # HDD 931 GB — una partición cubriendo todo, vdev de tank
      hdd = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WD10EZEX-00WN4A0_WD-WCC6Y4DYRJJ7";
        content = {
          type = "gpt";
          partitions = {
            tank = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "tank";
              };
            };
          };
        };
      };
    };

    zpool = {
      rpool = {
        type = "zpool";
        rootFsOptions = {
          compression = "zstd";
          acltype = "posixacl";
          xattr = "sa";
          atime = "off";
          "com.sun:auto-snapshot" = "false";
          mountpoint = "none";
        };
        options = {
          ashift = "12";
          autotrim = "on";
        };

        datasets = {
          "root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options.mountpoint = "legacy";
          };
          "nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              mountpoint = "legacy";
              "com.sun:auto-snapshot" = "false";
            };
          };
          "home" = {
            type = "zfs_fs";
            mountpoint = "/home";
            options = {
              mountpoint = "legacy";
              "com.sun:auto-snapshot" = "true";
            };
          };
          "var" = {
            type = "zfs_fs";
            mountpoint = "/var";
            options.mountpoint = "legacy";
          };
          "persist" = {
            type = "zfs_fs";
            mountpoint = "/persist";
            options.mountpoint = "legacy";
          };
          "reserved" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              refreservation = "2G";
            };
          };
          "services" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              "com.sun:auto-snapshot" = "false";
            };
          };
          "services/vaultwarden" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/vaultwarden";
            options = {
              mountpoint = "legacy";
              recordsize = "16K";
            };
          };
          "services/uptime-kuma" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/uptime-kuma";
            options = {
              mountpoint = "legacy";
              recordsize = "16K";
            };
          };
          "services/homepage" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/homepage";
            options.mountpoint = "legacy";
          };
        };
      };

      tank = {
        type = "zpool";
        rootFsOptions = {
          compression = "zstd";
          acltype = "posixacl";
          xattr = "sa";
          atime = "off";
          mountpoint = "none";
        };
        options = {
          ashift = "12";
        };

        datasets = {
          "storage" = {
            type = "zfs_fs";
            mountpoint = "/srv/storage";
            options.mountpoint = "legacy";
          };
          "storage/shares" = {
            type = "zfs_fs";
            mountpoint = "/srv/storage/shares";
            options.mountpoint = "legacy";
          };
          "storage/media" = {
            type = "zfs_fs";
            mountpoint = "/srv/storage/media";
            options.mountpoint = "legacy";
          };
          "backups" = {
            type = "zfs_fs";
            mountpoint = "/srv/backups";
            options.mountpoint = "legacy";
          };
          "reserved" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              refreservation = "8G";
            };
          };
        };
      };
    };
  };
}
