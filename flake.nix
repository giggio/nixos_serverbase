{
  description = "NixOS configuration";
  inputs = {
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
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

  outputs = inputs@{ self, nixpkgs, home-manager, nixos-hardware, nixos-generators, sops-nix, flake-utils, ... }:
    let
      lib = nixpkgs.lib;
      username = "giggio";
      common_options = { setup.username = username; };
      makeBaseModules = { virtualbox ? false, ... }:
        [
          ./options.nix
          ./configuration.nix
          common_options
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              users.${username} = ./home.nix;
              extraSpecialArgs = { inherit inputs; };
              sharedModules = [
                ./options.nix
                common_options
              ];
            };
          }
        ] ++ (if virtualbox then [
          ./vm.nix
        ] else [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          nixos-hardware.nixosModules.raspberry-pi-4
          ./kernel-configuration.nix
        ]);
      specialArgs = { inherit inputs; };
      mkNixosSystem = { system, virtualbox ? false, ... }:
        let
          modules = makeBaseModules { inherit virtualbox; };
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = modules;
          inherit specialArgs;
        };
    in
    {
      nixosConfigurations = {
        nixos = mkNixosSystem {
          system = "aarch64-linux";
        };
        nixos_virtualbox = mkNixosSystem {
          system = "x86_64-linux";
          virtualbox = true;
        };
      };
    } //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        formatter = pkgs.nixpkgs-fmt;
        packages = {
          pi4 =
            let
              pi4 = (mkNixosSystem {
                system = "aarch64-linux";
              }).config.system.build.sdImage;
            in
            pkgs.runCommand "pi4-img" { } ''
              mkdir -p "$out"
              ln -s ${pi4}/sd-image/*.img.zst $out/nixos.img.zst
            '';
          vbox =
            let
              vbox = nixos-generators.nixosGenerate {
                inherit system;
                format = "virtualbox";
                modules = (makeBaseModules { virtualbox = true; }) ++ [
                  {
                    setup.virtualbox = true;
                    virtualbox = {
                      vmName = "pitest";
                      memorySize = 4096;
                    };
                  }
                ];
                inherit specialArgs;
              };
            in
            pkgs.runCommand "vbox-ova" { } ''
              mkdir -p "$out"
              if [ ${vbox}/*.ova == '${vbox}/*.ova' ]; then
                echo "No OVA found"
                ls -la "${vbox}"
                exit 1
              fi
              ln -s ${vbox}/*.ova $out/nixos.ova
            '';
        };
        devShells.default = pkgs.mkShell {
          name = "Image build environment";
          buildInputs = with pkgs; [
            guestfs-tools
            qemu-utils
            yq-go
            util-linux
          ];
        };
      }
    );
}
