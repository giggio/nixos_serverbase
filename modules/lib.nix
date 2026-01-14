{
  serverbaseModules,
  lib,
  inputs,
}:
{
  mkNixosSystem =
    {
      hardwareModule,
      modules ? [ ],
      system,
      extraConfiguration ? { },
      specialArgs ? { },
      ...
    }:
    lib.nixosSystem (
      {
        specialArgs = specialArgs // {
          inherit inputs;
        };
        modules =
          serverbaseModules.default
          ++ [
            hardwareModule
            { nixpkgs.hostPlatform = system; }
          ]
          ++ modules;
      }
      // extraConfiguration
    );

  mkNixosConfigurations =
    mkMachineModule: machinesData:
    let
      nixosConfigurations =
        lib.lists.fold (machine_accumulator: new_machine: machine_accumulator // new_machine) { }
          (
            map (
              machine:
              {
                "${machine.name}" = nixosConfigurations."${machine.name}_${machine.defaultArch}";
              }
              // (lib.foldr (config_accumulator: new_config: config_accumulator // new_config) { } (
                lib.lists.flatten (
                  map
                    (
                      isVirtualBox:
                      map
                        (
                          isDev:
                          map
                            (
                              system:
                              let
                                mkBaseConfig =
                                  {
                                    isDev ? false,
                                    hardwareModule,
                                  }:
                                  {
                                    inherit hardwareModule;
                                    system = if lib.strings.hasSuffix "-linux" system then system else "${system}-linux";
                                    modules =
                                      (mkMachineModule machine.name) ++ lib.optionals isDev [ { config.setup.environment = "dev"; } ];
                                  };
                                configName = "${machine.name}${if isDev then "dev" else ""}${
                                  if isVirtualBox then "_virtualbox" else ""
                                }_${system}";
                                should_build_system = isVirtualBox || machine.defaultArch == system;
                              in
                              lib.attrsets.optionalAttrs should_build_system {
                                "${configName}" = serverbaseModules.lib.mkNixosSystem (mkBaseConfig {
                                  inherit isDev;
                                  hardwareModule =
                                    if isVirtualBox then serverbaseModules.hardware.virtualbox else machine.hardwareModule;
                                });
                              }
                            )
                            [
                              "x86_64"
                              "aarch64"
                            ]
                        )
                        [
                          false
                          true
                        ]
                    )
                    [
                      false
                      true
                    ]
                )
              ))
            ) machinesData
          );
    in
    nixosConfigurations;

  mkImagePackages =
    {
      nixosConfigurations,
      machinesData,
      system,
      pkgs,
    }:
    lib.foldr (machine_accumulator: new_machine: machine_accumulator // new_machine) { } (
      map (machine: {
        "${machine.name}" =
          (
            if machine.hardwareModule == serverbaseModules.hardware.pi4 then
              serverbaseModules.lib.mkPi4Image
            else if machine.hardwareModule == serverbaseModules.hardware.gmktec then
              serverbaseModules.lib.mkISOIntallerImage
            else
              "unexpected hardware module"
          )
            {
              inherit pkgs;
              nixos-system = nixosConfigurations."${machine.name}";
            };
        "${machine.name}_virtualbox" = serverbaseModules.lib.mkVboxImage {
          inherit pkgs;
          nixos-system =
            nixosConfigurations."${machine.name}_virtualbox_${lib.strings.removeSuffix "-linux" system}";
        };
      }) machinesData
    );

  mkPi4Image =
    { pkgs, nixos-system }:
    pkgs.runCommand "${nixos-system.config.setup.hostName}_img" { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.system.build.sdImage}/sd-image/*.img.zst $out/${nixos-system.config.setup.hostName}.img.zst
    '';

  mkISOIntallerImage =
    { pkgs, nixos-system }:
    pkgs.runCommand "${nixos-system.config.setup.hostName}_iso" { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.system.build.isoImage}/iso/*.iso $out/${nixos-system.config.setup.hostName}.iso
    '';

  mkVboxImage =
    { pkgs, nixos-system }:
    pkgs.runCommand "${nixos-system.config.setup.hostName}_ova" { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.formats.virtualbox}/*.ova $out/${nixos-system.config.setup.hostName}.ova
    '';

  list_machines =
    { pkgs, machines, ... }:
    let
      machinesWithDev = machines ++ (lib.map (m: "${m}dev") machines);
    in
    pkgs.runCommand "list_machines" { } ''
      mkdir -p "$out/bin"
      echo -e '#!/usr/bin/env bash\n\necho -e "${lib.strings.concatStringsSep "\n" machinesWithDev}"' > "$out/bin/list_machines";
      chmod +x "$out/bin/list_machines";
    '';

  mkDevShell =
    {
      pkgs,
      system,
      extraModules ? [ ],
    }:
    pkgs.mkShell {
      name = "Image build environment";
      buildInputs =
        with pkgs;
        [
          util-linux
          sops
        ]
        ++ (lib.optionals (system == "x86_64-linux") [
          # these libs are used to build VirtualBox machines, not necessary in the RPi
          guestfs-tools # not available in the RPi
          qemu-utils
          yq-go
          # virtualboxHeadless # see flake.nix comment
        ])
        ++ extraModules;
    };
}
