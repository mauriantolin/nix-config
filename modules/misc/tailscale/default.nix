{ config, lib, pkgs, ... }:
{
  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "server";
    # authKey se suministra vía agenix — ruta montada por agenix.
    authKeyFile = config.age.secrets.tailscaleAuthKey.path;
    extraUpFlags = [
      "--hostname=home-server"
      "--advertise-exit-node"
      "--ssh"
      "--reset"
    ];
  };

  # Desactiva reverse-path filter en interfaz Tailscale (necesario para exit-node).
  networking.firewall.checkReversePath = "loose";
}
