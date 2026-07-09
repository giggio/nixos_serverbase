{
  inputs,
  lib,
  modules,
  ...
}:
let
  myModules = {
    hardware =

      {
        gmktec =
          {
            physical ? [ ],
            virtual ? [ ],
            virtualboot ? [ ],
            ...
          }:
          {
            physical = {
              imports = [
                ./config-physical.nix
                ./config-physical-gmktec.nix
                ./config-gmktec.nix
              ]
              ++ physical;
            };
            virtual = {
              imports = [
                ./config-virtual.nix
                ./config-gmktec.nix
              ]
              ++ virtual;
            };
            virtualboot = {
              imports = [
                ./config-physical.nix
                ./config-physical-gmktec.nix
                ./config-gmktec.nix
                ./config-virtual-boot.nix
              ]
              ++ virtualboot;
            };
          };
        pi4 =
          {
            physical ? [ ],
            virtual ? [ ],
            ...
          }:
          {
            physical = {
              imports = [
                ./config-physical.nix
                ./config-physical-pi4.nix
                ./config-pi4.nix
              ]
              ++ physical;
            };
            virtual = {
              imports = [
                ./config-virtual.nix
                ./config-pi4.nix
              ]
              ++ virtual;
            };
          };
        opi4pro =
          {
            physical ? [ ],
            virtual ? [ ],
            ...
          }:
          {
            physical = {
              imports = [
                ./config-physical.nix
                ./config-physical-opi4pro.nix
                ./config-opi4pro.nix
              ]
              ++ physical;
            };
            virtual = {
              imports = [
                ./config-virtual.nix
                # ./config-pi4.nix
              ]
              ++ virtual;
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
