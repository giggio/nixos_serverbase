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
      setup = {
        user = "giggio";
        virtualbox = false;
      };
      baseModules = [
        ./configuration.nix
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            users.${setup.user} = ./home.nix;
            extraSpecialArgs = { inherit setup; inherit inputs; };
            sharedModules = [ ];
          };
        }
      ];
      baseSpecialArgs = { inherit inputs; };
      mkNixosSystem = { specialArgs, system, ... }:
        let
          modules = baseModules ++ (if specialArgs.setup.virtualbox then [
          ] else [
            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
            nixos-hardware.nixosModules.raspberry-pi-4
            ./kernel-configuration.nix
          ]);
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = modules;
          specialArgs = baseSpecialArgs // specialArgs;
        };
    in
    {
      nixosConfigurations = {
        nixos = mkNixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit setup; };
        };
        nixos_virtualbox = mkNixosSystem {
          system = "x86_64-linux";
          specialArgs = { setup = setup // { virtualbox = true; }; };
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
                specialArgs = { inherit setup; };
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
                modules = baseModules ++ [
                  {
                    virtualbox = {
                      vmName = "pitest";
                      memorySize = 4096;
                    };
                  }
                ];
                specialArgs = baseSpecialArgs // { setup = setup // { virtualbox = true; }; };
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
