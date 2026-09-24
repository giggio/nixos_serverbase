# Built with nixpkgs' own rustPlatform rather than a pinned-toolchain one (fenix). fenix tracks upstream Rust releases, so its
# toolchain derivation moved on every flake update and dragged this whole crate graph into a rebuild with it - on aarch64 that
# is a recompile under emulation, weekly, for a binary whose source is pinned to a fixed rev below. The release channel's rustc
# only moves when the channel does. Nothing here needs a nightly feature.
{
  lib,
  fetchgit,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "systemd_traefik_configuration_provider";
  version = "0.2.0";

  src = fetchgit {
    url = "https://codeberg.org/giggio/systemd_traefik_configuration_provider.git";
    rev = "321571cd0c38489a6a1a31c5e691ca4f15b027ef";
    hash = "sha256-2jTBT/9N2P40R6qXRuc/DWnb4Q3ApT/kZXhl0uPgssg=";
  };

  # A vendor hash, and NOT `cargoLock.lockFile = "${src}/Cargo.lock"`. That form reads a file out of a DERIVATION, so merely
  # evaluating anything that mentions this package - every machine that enables the service, and the ISOs that wrap one -
  # imports from a derivation: nix stops, clones the repository from codeberg, and only then finishes evaluating. `make eval`
  # is documented as building nothing and would build that, in the middle of the most expensive evaluation there is, inside
  # CI's 4G guest. This hash is read at eval time and the vendoring happens where it belongs, in a build.
  #
  # It covers the crate set `src`'s Cargo.lock names, so it moves when that lock does - which is to say when `rev` above
  # moves, and never on its own. `nix build` prints the new value on a mismatch.
  cargoHash = "sha256-p+eqsx3KWi+nvFYXMr+NEonletw1lsyDnyRBCg7qAK4=";

  meta = with lib; {
    description = "Traefik Configuration Provider from systemd";
    homepage = "https://codeberg.org/giggio/systemd_traefik_configuration_provider";
    license = licenses.mit;
  };
}
