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
    {
      pkgs,
      system,
      modules,
      specialArgs ? { },
    }:
    let
      vbox = inputs.nixos-generators.nixosGenerate {
        inherit system;
        modules = makeBaseModules {
          virtualbox = true;
          inherit modules;
        };
        specialArgs = specialArgs // {
          inherit inputs;
        };
        format = "virtualbox";
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
