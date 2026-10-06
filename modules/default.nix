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
    # The helpers (mkNixosConfigurations, mkChecks, ...) hand `inputs` to every machine module and check node. A
    # repository that has inputs of its own, and modules that need them, builds the helpers through this instead of
    # using `lib`, so its inputs show up in `inputs` beside serverbase's. The consumer's win on a clash, so passing its
    # whole `inputs` works: it is how a consumer's own `nixpkgs` (which follows serverbase's) and `self` get here.
    #
    # The helpers call each other through `serverbaseModules.lib` (mkNixosConfigurations reaches mkNixosModulesCombinations
    # that way, and that is where `specialArgs` is built), so the lib being built is also the `lib` they see.
    mkLib =
      extraInputs:
      let
        extendedLib = import ./lib.nix {
          serverbaseModules = myModules // {
            lib = extendedLib;
          };
          inherit lib;
          inputs = inputs // extraInputs;
        };
      in
      extendedLib;
    lib = myModules.mkLib { };
    default = [
      inputs.sops-nix.nixosModules.sops
      ./serverbase/default.nix
    ];
  };
in
myModules
