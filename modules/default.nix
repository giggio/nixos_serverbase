{
  inputs,
  lib,
  modules,
  ...
}:
let
  myModules = {
    hardware =
      # Every hardware module exposes the same variants: `physical` for the real board, `virtual`/`virtualboot` for the qemu
      # VMs built by the Makefile, and `test` for nixosTest nodes. `test` deliberately carries only the machine-identity
      # modules - the nixosTest driver builds and boots the VM itself, so importing config-virtual.nix (and through it
      # qemu-vm.nix) would fight it, and config-physical.nix would drag in disko and the real bootloader.
      {
        gmktec =
          {
            physical ? [ ],
            virtual ? [ ],
            virtualboot ? [ ],
            test ? [ ],
            ...
          }:
          {
            test = {
              imports = [ ./config-gmktec.nix ] ++ test;
            };
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
            test ? [ ],
            ...
          }:
          {
            test = {
              imports = [ ./config-pi4.nix ] ++ test;
            };
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
            test ? [ ],
            ...
          }:
          {
            test = {
              imports = [ ./config-opi4pro.nix ] ++ test;
            };
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
                ./config-opi4pro.nix
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
