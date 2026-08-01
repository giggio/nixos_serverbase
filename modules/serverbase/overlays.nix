# The overlays every server gets. Kept in its own file so that tests/custom-packages.nix can build the very same package
# set a machine ends up with, instead of a second declaration of it that drifts.
{ }:

[
  (final: prev: (import ./pkgs/default.nix { pkgs = prev; }))
]
