{
  description = "NixOS configuration";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    # Toolchain for the opi4pro vendor boot chain (kernel, U-Boot, their cross compilers) - see the header of
    # modules/config-physical-opi4pro-common.nix. Deliberately a REV, not a branch: `nix flake update` must not move it.
    # Bump this at a nixpkgs release change, or when touching the kernel config/patches - i.e. when a rebuild is happening
    # anyway. There is no security argument for bumping it on its own: nothing here links against the pinned userland.
    nixpkgs-bootchain.url = "github:nixos/nixpkgs/8623c4c20aa4ca2f5fb81510d2944066c3fb0d96"; # nixos-26.05, 2026-07-26
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      lib = nixpkgs.lib;
      machines = [
        {
          name = "pi4";
          defaultArch = "aarch64";
          hardwareModule = self.nixosModules.hardware.pi4 { };
          modules = [ ./configuration.nix ];
          supportsIso = false;
          supportsImg = true;
        }
        {
          name = "gmktec1";
          defaultArch = "x86_64";
          hardwareModule = self.nixosModules.hardware.gmktec { };
          modules = [ ./configuration.nix ];
          supportsIso = true;
          supportsImg = false;
          vmMemorySize = 8;
          vmDiskSize = 48;
          useEFIBoot = true;
        }
        {
          name = "opi4pro";
          defaultArch = "aarch64";
          hardwareModule = self.nixosModules.hardware.opi4pro { };
          modules = [ ./configuration.nix ];
          supportsIso = false;
          supportsImg = true;
          extraDisks = [
            100
            100
            100
          ];
          # The _img packages for this machine are UNATTENDED INSTALLER images, not full-system images: the SD card boots an
          # installer that wipes /dev/nvme0n1 with disko and installs this machine system onto it, pulling the pre-built
          # closure from the attic cache. The SD card then stays in the board permanently, holding only the boot chain (the
          # SoC boot ROM cannot boot from NVMe). See modules/setup-opi4pro.nix.
          imgIsInstaller = true;
        }
      ];
      nixosConfigurations = self.nixosModules.lib.mkNixosConfigurations machines;
    in
    {
      inherit nixosConfigurations;
      nixosModules = import ./modules/default.nix {
        inherit inputs lib;
        modules = self.nixosConfigurations;
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        formatter = pkgs.nixfmt-tree;
        checks = self.nixosModules.lib.mkChecks {
          inherit pkgs machines nixosConfigurations;
          tests = import ./tests;
        };
        packages = {
          list_machines = self.nixosModules.lib.list_machines { inherit pkgs machines; };
        }
        // self.nixosModules.lib.machine_details { inherit pkgs machines; }
        // self.nixosModules.lib.mkInstallerPackages {
          inherit nixosConfigurations machines;
        };
        devShells = self.nixosModules.lib.mkDevShells {
          inherit pkgs;
          inherit system;
        };
      }
    );
}
