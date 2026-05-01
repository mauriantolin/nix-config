# Web vault con botón SSO del fork Timshel/oidc_web_vault. El release ya viene
# pre-buildeado (no requiere npm/dart-sass), solo unpack + copy.
#
# La variante "button" mantiene el login form clásico + agrega el botón "Use
# Single-Sign On" al lado. La variante "override" reemplaza completamente
# (forzando SSO). Para nosotros el admin mauri necesita login local también
# (en caso de que KC esté caído), así que usamos "button".
{ lib, stdenvNoCC, fetchurl }:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "vaultwarden-webvault-oidc";
  version = "2026.4.1-3";

  src = fetchurl {
    url = "https://github.com/Timshel/oidc_web_vault/releases/download/v${finalAttrs.version}/oidc_button_web_vault.tar.gz";
    hash = "sha256-7zvFgdt5d0CWswoNclZ/rEw6kFYok+psZy3v+STDMqY=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/vaultwarden
    # El tarball ya contiene el dir `web-vault/`. Renombramos a `vault/` para
    # cumplir el contract del módulo NixOS (services.vaultwarden.config.WEB_VAULT_FOLDER
    # apunta a $out/share/vaultwarden/vault).
    if [ -d web-vault ]; then
      mv web-vault $out/share/vaultwarden/vault
    elif [ -d vault ]; then
      mv vault $out/share/vaultwarden/vault
    else
      echo "ERROR: tarball estructura inesperada" >&2
      ls -la
      exit 1
    fi
    runHook postInstall
  '';

  meta = {
    description = "Vaultwarden web vault con botón SSO (fork Timshel)";
    homepage = "https://github.com/Timshel/oidc_web_vault";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.all;
  };
})
