{
  pkgs,
  lib,
  inputs,
  ...
}:

# Covers the packages modules/serverbase/pkgs/default.nix adds to nixpkgs. Building them already happens as a side effect
# of building a machine; what is checked here is that they actually work, which a successful build does not prove - a lua
# wrapper missing a module, or a binary that cannot start, builds perfectly well. A plain derivation, so it costs seconds.
let
  # the packages only exist once the machines' overlays are applied, so the check builds them the same way a machine does
  serverPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = import ../modules/serverbase/overlays.nix { };
  };

  # Modules that mylua is expected to provide. The require names are what a config actually calls, which is not always
  # the nixpkgs attribute name (luasystem is required as `system`), so they are spelled out rather than derived.
  luaModules = [
    "inspect"
    "tiktoken_core"
    "busted"
    "system"
  ];
in
pkgs.runCommand "custom-packages" { } ''
  echo "mylua provides lua 5.1"
  ${serverPkgs.mylua}/bin/lua -v 2>&1 | grep -qF "Lua 5.1"

  ${lib.concatMapStringsSep "\n" (module: ''
    echo "mylua can require ${module}"
    ${serverPkgs.mylua}/bin/lua -e 'require("${module}")'
  '') luaModules}

  echo "mylua ships the luarocks package manager"
  ${serverPkgs.mylua}/bin/luarocks --version > /dev/null

  echo "the traefik configuration provider starts and describes itself"
  ${serverPkgs.systemd_traefik_configuration_provider}/bin/systemd_traefik_configuration_provider --help > /dev/null

  touch $out
''
