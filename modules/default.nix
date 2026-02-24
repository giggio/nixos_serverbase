{
  inputs,
  lib,
  modules,
  ...
}:
let
  myModules = {
    hardware = {
      gmktec = {
        physical = {
          imports = [
            ./config-physical.nix
            ./config-physical-gmktec.nix
            ./config-gmktec.nix
          ];
        };
        virtual = {
          imports = [
            ./config-virtual.nix
            ./config-gmktec.nix
          ];
        };
      };
      pi4 = {
        physical = {
          imports = [
            ./config-physical.nix
            ./config-physical-pi4.nix
            ./config-pi4.nix
          ];
        };
        virtual = {
          imports = [
            ./config-virtual.nix
            ./config-pi4.nix
          ];
        };
      };
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
