{
  description = "NixOS configuration";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11"; # or unstable: github:nixos/nixpkgs/nixos-unstable
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      home-manager,
      nixos-hardware,
      nixos-generators,
      sops-nix,
      flake-utils,
      ...
    }:
    let
      lib = nixpkgs.lib;
      machines = [
        {
          name = "pi4";
          defaultArch = "aarch64";
          hardwareModule = self.nixosModules.hardware.pi4;
          modules = [ ./configuration.nix ];
          supportsIso = false;
          supportsImg = true;
        }
        {
          name = "gmktec1";
          defaultArch = "x86_64";
          hardwareModule = self.nixosModules.hardware.gmktec;
          modules = [ ./configuration.nix ];
          supportsIso = true;
          supportsImg = false;
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
        checks = {
          boot-test = pkgs.testers.nixosTest (import ./tests/default.nix { inherit pkgs inputs; });
        };
        packages = {
          list_machines = self.nixosModules.lib.list_machines { inherit pkgs machines; };
        }
        // self.nixosModules.lib.mkInstallerPackages {
          inherit nixosConfigurations machines;
        };
        devShells.default = self.nixosModules.lib.mkDevShell {
          inherit pkgs;
          inherit system;
        };
      }
    );
}
