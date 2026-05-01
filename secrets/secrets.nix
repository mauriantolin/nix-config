let
  # User pubkey — la misma que autorizamos para SSH en authorizedKeys, usada para editar secretos
  # desde la PC del user con `agenix -e`.
  mauricio = "ssh-ed25519 AAAA... mauri@DESKTOP-3N81VTT";  # REEMPLAZAR en Task 2.0 Step 2

  # Host pubkey — la ed25519 del home-server nuevo. Generada en Task 2.3.
  homeServer = "ssh-ed25519 AAAA... root@home-server";  # REEMPLAZAR en Task 2.3

  users = [ mauricio ];
  systems = [ homeServer ];
in
{
  "tailscale-authkey.age".publicKeys = users ++ systems;
  "mauri-hashed-password.age".publicKeys = users ++ systems;
  "hello-secret.age".publicKeys = users ++ systems;
}
