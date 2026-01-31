{
  rust-toolchain-fenix,
  lib,
  fetchgit,
  makeRustPlatform,
}:

(makeRustPlatform {
  cargo = rust-toolchain-fenix;
  rustc = rust-toolchain-fenix;
}).buildRustPackage
  rec {
    pname = "systemd_traefik_configuration_provider";
    version = "0.1.0";

    src = fetchgit {
      url = "https://codeberg.org/giggio/systemd_traefik_configuration_provider.git";
      rev = "4db2180bee7928e46ef783b89734bd1c99b058bd";
      hash = "sha256-QJHGnQrQhIAZR+ko+8/orSoJh/+/3Iq+bkMK6N4GqG0=";
    };

    cargoLock.lockFile = "${src}/Cargo.lock";

    meta = with lib; {
      description = "Traefik Configuration Provider from systemd";
      homepage = "https://codeberg.org/giggio/systemd_traefik_configuration_provider";
      license = licenses.mit;
    };
  }
