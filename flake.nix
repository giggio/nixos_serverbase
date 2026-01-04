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

  outputs = inputs@{ self, nixpkgs, home-manager, nixos-hardware, nixos-generators, sops-nix, flake-utils, ... }:
    let
      lib = nixpkgs.lib;
      username = "giggio";
      common_options = { setup.username = username; };
      makeBaseModules = { system ? "", virtualbox ? false }:
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
          (if system == "" then { } else { nixpkgs.hostPlatform = system; })
        ] ++ (if virtualbox then [
          ./vm.nix
        ] else [
          ./kernel-configuration.nix
        ]);
      specialArgs = { inherit inputs; };
      mkNixosSystem = { virtualbox ? false, modules ? [ ], system ? "", ... }@additionalConfiguration:
        let
          extraModules = (makeBaseModules { inherit virtualbox; inherit system; }) ++ modules;
        in
        nixpkgs.lib.nixosSystem
          {
            modules = extraModules;
            inherit specialArgs;
          } // additionalConfiguration;
      nixosConfigurations = nixpkgs.lib.foldr (a: b: a // b) { } (map
        (system:
          {
            "nixos_${system}" = mkNixosSystem { system = "${system}-linux"; };
            "nixos_virtualbox_${system}" = mkNixosSystem {
              system = "${system}-linux";
              virtualbox = true;
            };
          }
        ) [ "x86_64" "aarch64" ]);
    in
    {
      inherit nixosConfigurations;
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
                modules = [{ nixpkgs.hostPlatform = "aarch64-linux"; }]; # this is what makes cross compilation work
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
                modules = makeBaseModules { virtualbox = true; };
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
            sops
            # virtualboxHeadless # this conflicts with the VirtualBox installed on Ubuntu, versions don't match and calls to VBoxHeadless fail, install VirtualBox manually
          ];
        };
      }
    );
}
