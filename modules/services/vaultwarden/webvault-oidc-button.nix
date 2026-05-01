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
    # El tarball extrae sus archivos directamente al cwd (sin wrapper dir):
    # index.html + assets/ + locales/ + scripts/ etc. Movemos TODO a vault/.
    install -d $out/share/vaultwarden
    cp -R "$PWD" $out/share/vaultwarden/vault
    runHook postInstall
  '';

  meta = {
    description = "Vaultwarden web vault con botón SSO (fork Timshel)";
    homepage = "https://github.com/Timshel/oidc_web_vault";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.all;
  };
})
