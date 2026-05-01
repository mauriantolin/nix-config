{ config, lib, pkgs, inputs, ... }:
let
  secretsRoot = "${inputs.secrets}/secrets";
in
{
  age.identityPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  age.secrets = {
    tailscaleAuthKey = {
      file = "${secretsRoot}/tailscale-authkey.age";
      mode = "0400";
      owner = "root";
      group = "root";
    };
    mauri-password = {
      file = "${secretsRoot}/mauri-hashed-password.age";
      mode = "0400";
      owner = "root";
      group = "root";
    };
    hello-secret = {
      file = "${secretsRoot}/hello-secret.age";
      mode = "0444";
      owner = "root";
      group = "root";
    };
  };
}
