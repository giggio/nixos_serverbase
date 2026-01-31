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
      rev = "cef3f9873bcb73bfc979773a0e9e3420da83d529";
      hash = "sha256-xLfPOWu6wnHfYuGhQcml2Fd4LG89ED5jkn20cgooq5M=";
    };

    cargoLock.lockFile = "${src}/Cargo.lock";

    meta = with lib; {
      description = "Traefik Configuration Provider from systemd";
      homepage = "https://codeberg.org/giggio/systemd_traefik_configuration_provider";
      license = licenses.mit;
    };
  }
