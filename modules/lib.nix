{
  serverbaseModules,
  lib,
  inputs,
}:
{
  mkNixosConfigurations =
    machines:
    let
      nixosConfigurations =
        lib.lists.fold (newConfig: configAccumulator: configAccumulator // newConfig) { }
          (
            (map (machine: ({
              "${machine.name}" = nixosConfigurations."${machine.name}_${machine.defaultArch}";
              "${machine.name}dev" = nixosConfigurations."${machine.name}dev_${machine.defaultArch}";
            })) machines)
            ++ (map (config: {
              "${config.name}" = config.configuration;
            }) (serverbaseModules.lib.mkNixosModulesCombinations machines))
          );
    in
    builtins.mapAttrs (_: module: lib.nixosSystem module) nixosConfigurations;

  mkNixosMachineCombinations =
    machines:
    let
      combinations =
        builtins.filter
          # only build if architecture matches or it is a vm
          (combination: (combination.isVM || combination.machine.defaultArch == combination.system))
          (
            lib.lists.flatten (
              map (
                machine:
                map
                  (
                    isVM:
                    map
                      (
                        isDev:
                        map
                          (system: {
                            inherit
                              machine
                              isVM
                              isDev
                              system
                              ;
                          })
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
              ) machines
            )
          );
    in
    combinations;

  mkNixosModulesCombinations =
    machines:
    let
      combinations = serverbaseModules.lib.mkNixosMachineCombinations machines;
    in
    map (
      combination:
      let
        name = serverbaseModules.lib.mkNixosModuleName combination;
        suffixedSystem =
          if lib.strings.hasSuffix "-linux" combination.system then
            combination.system
          else
            "${combination.system}-linux";
      in
      {
        inherit name;
        system = suffixedSystem;
        configuration = {
          specialArgs = {
            inherit inputs;
            helpers = import ./helpers { inherit lib; };
          }
          // (if combination.machine ? specialArgs then combination.machine.specialArgs else { });
          system = suffixedSystem;
          modules =
            serverbaseModules.default
            ++ [
              (
                if combination.isVM then
                  combination.machine.hardwareModule.virtual
                else
                  combination.machine.hardwareModule.physical
              )
              {
                nixpkgs.hostPlatform = suffixedSystem;
                setup.hostName = combination.machine.name;
                setup.vm.memorySize = lib.mkIf (
                  combination.machine ? vmMemorySize
                ) combination.machine.vmMemorySize;
                setup.vm.diskSize = lib.mkIf (combination.machine ? vmDiskSize) combination.machine.vmDiskSize;
                setup.vm.useEFIBoot =
                  if (combination.machine ? useEFIBoot) then combination.machine.useEFIBoot else false;
              }
              (lib.attrsets.optionalAttrs combination.isDev { config.setup.environment = "dev"; })
            ]
            ++ combination.machine.modules;
        };
      }
    ) combinations;

  mkNixosModuleName =
    {
      machine,
      isDev,
      isVM,
      system,
      ...
    }:
    "${machine.name}${if isDev then "dev" else ""}_${lib.strings.removeSuffix "-linux" system}${if isVM then "_vm" else ""}";

  mkInstallerPackages =
    {
      nixosConfigurations,
      machines,
    }:
    let
      combinations = serverbaseModules.lib.mkNixosMachineCombinations machines;
      nixosModules = serverbaseModules.lib.mkNixosModulesCombinations machines;
      evalConfig = import "${inputs.nixpkgs}/nixos/lib/eval-config.nix";
      pi4Machines = builtins.filter (
        machine: machine.hardwareModule == serverbaseModules.hardware.pi4
      ) machines;
      installerPackages =
        lib.lists.fold (packageAccumulator: newPackage: packageAccumulator // newPackage) { } (
          map (
            combination:
            lib.attrsets.optionalAttrs combination.isVM {
              # machine isVM isDev system
              "${serverbaseModules.lib.mkNixosModuleName combination}" = serverbaseModules.lib.mkVmImage {
                pkgs = import inputs.nixpkgs { system = "${combination.system}-linux"; };
                nixos-system = nixosConfigurations."${serverbaseModules.lib.mkNixosModuleName combination}";
                isDev = combination.isDev;
              };
            }
            // lib.attrsets.optionalAttrs (combination.machine.supportsIso && combination.isVM == false) {
              "${serverbaseModules.lib.mkNixosModuleName combination}_iso" =
                let
                  configName = serverbaseModules.lib.mkNixosModuleName combination;
                  theConfiguration = lib.lists.findFirst (
                    module: module.name == configName
                  ) "unexpected module name" nixosModules;
                in
                serverbaseModules.lib.mkIsoPackage {
                  pkgs = import inputs.nixpkgs { system = theConfiguration.system; };
                  isDev = combination.isDev;
                  isVM = combination.isVM;
                  installedSystem = evalConfig theConfiguration.configuration;
                };
            }
          ) combinations
        )
        // lib.fold (machine_accumulator: new_machine: machine_accumulator // new_machine) { } (
          map (machine: {
            "${machine.name}_img" = serverbaseModules.lib.mkPi4Image {
              pkgs = import inputs.nixpkgs { system = "${machine.defaultArch}-linux"; };
              nixos-system = nixosConfigurations."${machine.name}";
              isDev = false;
            };
            "${machine.name}dev_img" = serverbaseModules.lib.mkPi4Image {
              pkgs = import inputs.nixpkgs { system = "${machine.defaultArch}-linux"; };
              nixos-system = nixosConfigurations."${machine.name}dev";
              isDev = true;
            };
          }) pi4Machines
        );
    in
    installerPackages
    // lib.fold (machine_accumulator: new_machine: machine_accumulator // new_machine) { } (
      map (machine: {
        "${machine.name}_iso" =
          installerPackages."${
            serverbaseModules.lib.mkNixosModuleName {
              inherit machine;
              isDev = false;
              isVM = false;
              system = machine.defaultArch;
            }
          }_iso";
        "${machine.name}dev_iso" =
          installerPackages."${
            serverbaseModules.lib.mkNixosModuleName {
              inherit machine;
              isDev = true;
              isVM = false;
              system = machine.defaultArch;
            }
          }_iso";
      }) (lib.filter (machine: machine.supportsIso) machines)
    );

  mkIsoPackage =
    {
      installedSystem,
      pkgs,
      isVM,
      isDev,
    }:
    let
      nixos-system = lib.nixosSystem {
        modules = [
          (
            { config, ... }:
            let
              cfg = installedSystem.config;
            in
            {
              imports = [
                "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/iso-image.nix"
                "${inputs.nixpkgs}/nixos/modules/profiles/minimal.nix"
              ];
              isoImage = {
                makeEfiBootable = true;
                makeUsbBootable = true;
              };
              swapDevices = lib.mkImageMediaOverride [ ];
              fileSystems = lib.mkImageMediaOverride config.lib.isoFileSystems; # An installation media cannot tolerate a host config defined file system layout on a fresh machine, before it has been formatted.
              boot = {
                loader.grub.memtest86.enable = true; # Add Memtest86+ to the CD.
                postBootCommands = ''
                  for o in $(</proc/cmdline); do
                    case "$o" in
                      live.nixos.passwd=*)
                        set -- $(IFS==; echo $o)
                        echo "nixos:$2" | ${pkgs.shadow}/bin/chpasswd
                        ;;
                    esac
                  done
                '';
                loader.timeout = lib.mkForce 2;
              };
              image.baseName = lib.mkForce cfg.setup.hostName;
              nixpkgs.pkgs = pkgs;
              fonts.fontconfig.enable = false; # Remove fonts to make ISO smaller
              networking.useDHCP = false;
              systemd.services.unattended-install = {
                description = "Unattended NixOS installation script";
                wantedBy = [ "multi-user.target" ];
                after = [ "getty.target" ]; # Prevent a login getty from starting so the script can output directly to the console
                conflicts = [ "getty@tty1.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  StandardInput = "tty-force";
                };
                path = [
                  cfg.system.build.destroyFormatMount
                  pkgs.nix
                  pkgs.nixos-install
                  pkgs.util-linux
                  pkgs.systemd
                  pkgs.kexec-tools
                ];
                script =
                  let
                    kernelImage = "${cfg.boot.kernelPackages.kernel}/${cfg.system.boot.loader.kernelFile}";
                    initRamdisk = "${cfg.system.build.initialRamdisk}/${cfg.system.boot.loader.initrdFile}";
                    initScript = "${cfg.system.build.toplevel}/init";
                    kernelArgs = "init=${initScript} ${lib.concatStringsSep " " cfg.boot.kernelParams}";
                  in
                  ''
                    echo ====== Partioning disk...
                    disko-destroy-format-mount --yes-wipe-all-disks
                    echo ====== Installing NixOS...
                    nixos-install --system ${cfg.system.build.toplevel} --no-root-passwd --substituters ""
                    echo ====== Installation complete, remember to eject the USB, CD, DVD or Blu-ray device!
                    echo ====== Kexec-ing new install...
                    kexec -l --initrd='${initRamdisk}' --command-line='${kernelArgs}' ${kernelImage}
                    kexec -e
                  '';
              };
              system.stateVersion = "25.11";
            }
          )
        ];
      };
      file = "${installedSystem.config.setup.hostName}${if isDev then "dev" else ""}${if isVM then "_vm" else ""}.iso";
    in
    pkgs.runCommand file { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.system.build.isoImage}/iso/*.iso $out/${file}
    '';

  mkPi4Image =
    {
      pkgs,
      nixos-system,
      isDev,
    }:
    let
      file = "${nixos-system.config.setup.hostName}${if isDev then "dev" else ""}.img.zst";
    in
    pkgs.runCommand file { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.system.build.sdImage}/sd-image/*.img.zst $out/${file}
    '';

  mkVmImage =
    {
      pkgs,
      nixos-system,
      isDev,
    }:
    let
      file = "run-${nixos-system.config.setup.derivedHostName}-vm";
    in
    pkgs.runCommand file { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.system.build.vm}/bin/${file} $out/${file}
    '';

  list_machines =
    { pkgs, machines, ... }:
    let
      machinesNames = map (m: m.name) machines;
      machinesNamesWithDev = machinesNames ++ (lib.map (m: "${m}dev") machinesNames);
      isoMachinesNames = map (m: m.name) (lib.filter (m: m.supportsIso) machines);
      isoMachinesNamesWithDev = isoMachinesNames ++ (lib.map (m: "${m}dev") isoMachinesNames);
      imgMachinesNames = map (m: m.name) (lib.filter (m: m.supportsImg) machines);
      imgMachinesNamesWithDev = imgMachinesNames ++ (lib.map (m: "${m}dev") imgMachinesNames);
    in
    pkgs.runCommand "list_machines" { } ''
      mkdir -p "$out/bin"
      echo -e '#!/usr/bin/env bash\n\necho -n "machines ${lib.strings.concatStringsSep " " machinesNamesWithDev}"' > "$out/bin/list_machines";
      echo 'echo -n "|isos ${lib.strings.concatStringsSep " " isoMachinesNamesWithDev}"' >> "$out/bin/list_machines";
      echo 'echo -n "|imgs ${lib.strings.concatStringsSep " " imgMachinesNamesWithDev}"' >> "$out/bin/list_machines";
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
          zellij
          qemu
        ]
        ++ (lib.optionals (system == "x86_64-linux") [
          # these libs are used to build VMs, not necessary in the RPi
          guestfs-tools
          qemu-utils
        ])
        ++ extraModules;
      shellHook = ''
        export VMS_DIR=/mnt/data/vms
      '';
    };
}
