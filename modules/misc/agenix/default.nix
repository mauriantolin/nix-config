{ config, lib, pkgs, inputs, ... }:
let
  secretsRoot = "${inputs.secrets}/secrets";
in
{
  age.identityPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  # Forzar que `agenixChown` corra DESPUÉS de la creación de users/groups del switch.
  # Default de ryantm/agenix: deps = [ "agenixInstall" ] — no espera a `users`. Si una
  # rebuild introduce un nuevo user (e.g. `keycloak` en D.3) y declara secrets owned
  # por él, el chown falla con `invalid user` porque /etc/passwd aún no tiene la entry.
  # Lección 2026-04-27 (D.3 deploy): brickeó switch en chown de 15 secretos keycloak.
  # NixOS lists merge concat → esto agrega "users"/"groups" a los deps existentes.
  system.activationScripts.agenixChown.deps = [ "users" "groups" ];

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
