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
    version = "0.1.1";

    src = fetchgit {
      url = "https://codeberg.org/giggio/systemd_traefik_configuration_provider.git";
      rev = "a41445127280dc4983cd2ae3edf65394f1b914c2";
      hash = "sha256-9N4Z7HnVEUW0d/YIf0FXIqJd6dx79JrCiMZb+fOb6ps=";
    };

    cargoLock.lockFile = "${src}/Cargo.lock";

    meta = with lib; {
      description = "Traefik Configuration Provider from systemd";
      homepage = "https://codeberg.org/giggio/systemd_traefik_configuration_provider";
      license = licenses.mit;
    };
  }
