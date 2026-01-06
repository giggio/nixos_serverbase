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
      modules = [ ./configuration.nix ];
    in
    {
      nixosConfigurations = lib.foldr (a: b: a // b) { } (
        map
          (
            system:
            let
              baseConfig = {
                system = "${system}-linux";
                inherit modules;
              };
            in
            {
              "nixos_${system}" = self.nixosModules.lib.mkNixosSystem baseConfig;
              "nixos_virtualbox_${system}" = self.nixosModules.lib.mkNixosSystem (
                { virtualbox = true; } // baseConfig
              );
            }
          )
          [
            "x86_64"
            "aarch64"
          ]
      );
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
          pi4 = self.nixosModules.lib.mkPi4Image {
            inherit pkgs;
            nixos-system = self.nixosModules.lib.mkNixosSystem {
              inherit modules;
              system = "aarch64-linux";
            };
          };
          vbox = self.nixosModules.lib.mkVboxImage {
            inherit pkgs system;
            modules = self.nixosModules.lib.makeBaseModules {
              virtualbox = true;
              inherit modules;
            };
          };
        };
        devShells.default = self.nixosModules.lib.mkDevShell { inherit pkgs; };
      }
    );
}
