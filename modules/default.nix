{
  inputs,
  lib,
  modules,
  ...
}:
let
  myModules = {
    hardware = {
      gmktec = ./config-physical-gmktec.nix;
      pi4 = ./config-physical-pi4.nix;
      virtualbox = ./config-virtual.nix;
    };
    lib = import ./lib.nix {
      serverbaseModules = myModules;
      inherit lib inputs;
    };
    default = [
      inputs.sops-nix.nixosModules.sops
      inputs.home-manager.nixosModules.home-manager
      ./serverbase/default.nix
    ];
  };
in
myModules
