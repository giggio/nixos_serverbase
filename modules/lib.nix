{
  serverbaseModules,
  lib,
  inputs,
}:
rec {
  makeBaseModules =
    {
      system ? "",
      virtualbox ? false,
      modules ? [ ],
    }:
    serverbaseModules.default
    ++ [
      (if system == "" then { } else { nixpkgs.hostPlatform = system; })
    ]
    ++ (
      if virtualbox then
        [
          inputs.nixos-generators.nixosModules.all-formats
          serverbaseModules.virtualbox
        ]
      else
        [
          serverbaseModules.pi4
        ]
    )
    ++ modules;

  mkNixosSystem =
    {
      virtualbox ? false,
      modules ? [ ],
      system ? "",
      extraConfiguration ? { },
      specialArgs ? { },
      ...
    }:
    lib.nixosSystem (
      {
        specialArgs = specialArgs // {
          inherit inputs;
        };
        modules = makeBaseModules {
          inherit virtualbox;
          inherit modules;
          inherit system;
        };
      }
      // extraConfiguration
    );

  mkPi4Image =
    { pkgs, nixos-system }:
    pkgs.runCommand "${nixos-system.config.setup.servername}_img" { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.system.build.sdImage}/sd-image/*.img.zst $out/nixos.img.zst
    '';

  mkVboxImage =
    { pkgs, nixos-system }:
    pkgs.runCommand "${nixos-system.config.setup.servername}_ova" { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.formats.virtualbox}/*.ova $out/nixos.ova
    '';

  mkDevShell =
    {
      pkgs,
      extraModules ? [ ],
    }:
    pkgs.mkShell {
      name = "Image build environment";
      buildInputs =
        with pkgs;
        [
          guestfs-tools
          qemu-utils
          yq-go
          util-linux
          sops
          # virtualboxHeadless # see flake.nix comment
        ]
        ++ extraModules;
    };
}
