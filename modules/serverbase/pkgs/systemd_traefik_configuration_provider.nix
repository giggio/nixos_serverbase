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
      rev = "7c9deff30978ca0d204b13c3740512e313125dcf";
      hash = "sha256-Pr9UBXbe7s5i1z63f7pAbUAHLG5yHu4OPj9oSWFxga8=";
    };

    cargoLock.lockFile = "${src}/Cargo.lock";

    meta = with lib; {
      description = "Traefik Configuration Provider from systemd";
      homepage = "https://codeberg.org/giggio/systemd_traefik_configuration_provider";
      license = licenses.mit;
    };
  }
