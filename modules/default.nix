{ inputs, lib, modules, ... }:
let
  myModules = {
    pi4 = ./config-physical.nix;
    virtualbox = ./config-virtual.nix;
    lib = import ./lib.nix { serverbaseModules = myModules; inherit lib inputs; };
    default = [
      inputs.sops-nix.nixosModules.sops
      inputs.home-manager.nixosModules.home-manager
      ./serverbase/default.nix
    ];
  };
in
  myModules
